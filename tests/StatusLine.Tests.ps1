$moduleRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $moduleRoot 'scripts\modules\StatusLine.psm1') -Force

Describe 'Test-PlanStatusLine' {
    It 'reconoce PLAN_STATUS: CONTINUE' {
        $result = Test-PlanStatusLine -Line 'PLAN_STATUS: CONTINUE'
        $result.IsValid | Should Be $true
        $result.Status | Should Be 'CONTINUE'
    }

    It 'reconoce PLAN_STATUS: COMPLETE' {
        $result = Test-PlanStatusLine -Line 'PLAN_STATUS: COMPLETE'
        $result.IsValid | Should Be $true
        $result.Status | Should Be 'COMPLETE'
    }

    It 'reconoce PLAN_STATUS: BLOCKED con motivo' {
        $result = Test-PlanStatusLine -Line 'PLAN_STATUS: BLOCKED: falta decision sobre esquema de datos'
        $result.IsValid | Should Be $true
        $result.Status | Should Be 'BLOCKED'
        $result.Reason | Should Be 'falta decision sobre esquema de datos'
    }

    It 'rechaza una linea sin marca' {
        $result = Test-PlanStatusLine -Line 'Listo, todo salio bien.'
        $result.IsValid | Should Be $false
    }

    It 'rechaza $null sin lanzar excepcion' {
        $result = Test-PlanStatusLine -Line $null
        $result.IsValid | Should Be $false
    }
}

Describe 'Resolve-DriverDecision' {
    It 'FAILED cuando el exit code no es cero, aunque la linea sea valida' {
        $result = Resolve-DriverDecision -ExitCode 1 -LastLine 'PLAN_STATUS: CONTINUE'
        $result.GlobalStatus | Should Be 'FAILED'
        $result.ShouldContinue | Should Be $false
    }

    It 'FAILED cuando no hay marca PLAN_STATUS' {
        $result = Resolve-DriverDecision -ExitCode 0 -LastLine 'sin marca'
        $result.GlobalStatus | Should Be 'FAILED'
        $result.ShouldContinue | Should Be $false
    }

    It 'DONE cuando la marca es COMPLETE' {
        $result = Resolve-DriverDecision -ExitCode 0 -LastLine 'PLAN_STATUS: COMPLETE'
        $result.GlobalStatus | Should Be 'DONE'
        $result.ShouldContinue | Should Be $false
    }

    It 'BLOCKED cuando la marca es BLOCKED, con motivo propagado' {
        $result = Resolve-DriverDecision -ExitCode 0 -LastLine 'PLAN_STATUS: BLOCKED: revisar esquema'
        $result.GlobalStatus | Should Be 'BLOCKED'
        $result.Reason | Should Be 'revisar esquema'
        $result.ShouldContinue | Should Be $false
    }

    It 'RUNNING y continua cuando la marca es CONTINUE' {
        $result = Resolve-DriverDecision -ExitCode 0 -LastLine 'PLAN_STATUS: CONTINUE'
        $result.GlobalStatus | Should Be 'RUNNING'
        $result.ShouldContinue | Should Be $true
    }

    It 'FAILED cuando LastLine es $null (log no existe o vacio)' {
        $result = Resolve-DriverDecision -ExitCode 0 -LastLine $null
        $result.GlobalStatus | Should Be 'FAILED'
        $result.ShouldContinue | Should Be $false
    }
}

Describe 'Find-LastPlanStatusLine' {
    It 'encuentra CONTINUE aunque haya texto colgante debajo (modo 1)' {
        $r = Find-LastPlanStatusLine -Lines @('- No inicie el nivel 3.', 'PLAN_STATUS: CONTINUE', '**Ciclo de review/fix:**')
        $r.IsValid | Should Be $true
        $r.Status | Should Be 'CONTINUE'
        $r.Line | Should Be 'PLAN_STATUS: CONTINUE'
    }

    It 'sin marca devuelve IsValid falso y Line nula' {
        $r = Find-LastPlanStatusLine -Lines @('texto', 'mas texto')
        $r.IsValid | Should Be $false
        $r.Status | Should BeNullOrEmpty
        $r.Line | Should BeNullOrEmpty
    }

    It 'con dos marcas gana la ultima en orden de archivo' {
        $r = Find-LastPlanStatusLine -Lines @('PLAN_STATUS: BLOCKED: algo', 'texto', 'PLAN_STATUS: CONTINUE')
        $r.Status | Should Be 'CONTINUE'
    }

    It 'acepta array vacio y $null sin lanzar excepcion' {
        (Find-LastPlanStatusLine -Lines @()).IsValid | Should Be $false
        (Find-LastPlanStatusLine -Lines $null).IsValid | Should Be $false
    }

    It 'conserva el motivo del BLOCKED' {
        $r = Find-LastPlanStatusLine -Lines @('PLAN_STATUS: BLOCKED: falta fixture', 'cola')
        $r.Status | Should Be 'BLOCKED'
        $r.Reason | Should Be 'falta fixture'
    }
}

Describe 'Resolve-SessionOutcome' {
    It 'marca seguida de texto con exit 0: RUNNING y continua (reproduce el modo 1)' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE', '**Ciclo de review/fix:**') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null
        $o.PlanStatusForEvent | Should Be 'CONTINUE'
        $o.PlanStatusReasonForEvent | Should BeNullOrEmpty
        $o.Decision.GlobalStatus | Should Be 'RUNNING'
        $o.Decision.ShouldContinue | Should Be $true
        $o.CloseGateApplied | Should Be $false
    }

    It 'sin marca: FAILED con el motivo actual' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('El implementer corre en segundo plano.') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null
        $o.PlanStatusForEvent | Should BeNullOrEmpty
        $o.Decision.GlobalStatus | Should Be 'FAILED'
        $o.Decision.Reason | Should Be 'no emitio marca PLAN_STATUS reconocible'
        $o.Decision.ShouldContinue | Should Be $false
    }

    It 'cola vacia (marca fuera de la ventana o log vacio): FAILED' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @() -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null
        $o.Decision.GlobalStatus | Should Be 'FAILED'
    }

    It 'dos marcas: gana la ultima' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE', 'x', 'PLAN_STATUS: BLOCKED: decidir esquema') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null
        $o.Decision.GlobalStatus | Should Be 'BLOCKED'
        $o.Decision.Reason | Should Be 'decidir esquema'
    }

    It 'exit code distinto de cero gana sobre una marca valida' {
        $o = Resolve-SessionOutcome -ExitCode 3 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null
        $o.Decision.GlobalStatus | Should Be 'FAILED'
        $o.Decision.Reason | Should Be 'exit code 3'
        $o.PlanStatusForEvent | Should Be 'CONTINUE'
    }

    It 'regresion BLOCKED (cuarto registro, parte A): BLOCKED con su motivo en la decision y en el evento' {
        $motivo = 'Task 13 (E2E Nivel 4) requiere una cuenta OPERADOR no-admin inexistente en los fixtures locales'
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('Resumen del nivel 4.', "PLAN_STATUS: BLOCKED: $motivo") -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null
        $o.PlanStatusForEvent | Should Be 'BLOCKED'
        $o.PlanStatusReasonForEvent | Should Be $motivo
        $o.Decision.GlobalStatus | Should Be 'BLOCKED'
        $o.Decision.Reason | Should Be $motivo
        $o.Decision.ShouldContinue | Should Be $false
        $o.CloseGateApplied | Should Be $false
    }

    It 'regresion compuerta de cierre: close + COMPLETE sin marcador se degrada a BLOCKED' {
        $marker = 'docs\superpowers\plans\.final-review-plan.md'
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('Revision final hecha.', 'PLAN_STATUS: COMPLETE') -Mode 'close' -FinalReviewMarkerExists $false -MarkerRelativePath $marker
        $o.PlanStatusForEvent | Should Be 'COMPLETE'
        $o.Decision.GlobalStatus | Should Be 'BLOCKED'
        $o.Decision.Reason | Should Be "la sesion de cierre declaro DONE pero no escribio el marcador de revision final ($marker)"
        $o.Decision.ShouldContinue | Should Be $false
        $o.CloseGateApplied | Should Be $true
    }

    It 'regresion compuerta de cierre: close + COMPLETE con marcador queda en DONE' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: COMPLETE') -Mode 'close' -FinalReviewMarkerExists $true -MarkerRelativePath 'docs\superpowers\plans\.final-review-plan.md'
        $o.Decision.GlobalStatus | Should Be 'DONE'
        $o.CloseGateApplied | Should Be $false
    }

    It 'close + CONTINUE: la compuerta no actua (solo aplica a DONE)' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'close' -FinalReviewMarkerExists $false -MarkerRelativePath 'x'
        $o.Decision.GlobalStatus | Should Be 'RUNNING'
        $o.CloseGateApplied | Should Be $false
    }

    It 'continue + COMPLETE sin marcador: DONE (la compuerta solo aplica en close)' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: COMPLETE') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null
        $o.Decision.GlobalStatus | Should Be 'DONE'
        $o.CloseGateApplied | Should Be $false
    }
}

Describe 'Test-ProseQuestion' {
    It 'una linea que termina en ? es pregunta' {
        Test-ProseQuestion -Line 'Prefieres la opcion A o la B?' | Should Be $true
    }
    It 'ignora cierres de markdown despues del ?' {
        Test-ProseQuestion -Line '**Sigo con el nivel 3?**' | Should Be $true
    }
    It 'una afirmacion no es pregunta' {
        Test-ProseQuestion -Line 'Listo.' | Should Be $false
    }
    It 'nulo o vacio no es pregunta' {
        Test-ProseQuestion -Line $null | Should Be $false
        Test-ProseQuestion -Line '' | Should Be $false
    }
}

Describe 'Resolve-SessionOutcome (Fase 2: causa, avance y reintentos)' {
    $bgErr = 'Background tasks still running after 600s; terminating. Set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 to wait indefinitely.'

    It 'fila 1: exit distinto de cero -> exit_no_cero, FAILED, no cuenta como sin avance' {
        $o = Resolve-SessionOutcome -ExitCode 3 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $false -ErrTailLines @() -NoProgressStreak 0 -NoProgressRetries 1
        $o.Cause | Should Be 'exit_no_cero'
        $o.Decision.GlobalStatus | Should Be 'FAILED'
        $o.Decision.Reason | Should Be 'exit code 3'
        $o.CountsAsNoProgress | Should Be $false
        $o.IsRetry | Should Be $false
    }

    It 'fila 2: CONTINUE sin avance con reintento disponible -> reintenta' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $false -ErrTailLines @() -NoProgressStreak 0 -NoProgressRetries 1
        $o.Cause | Should Be 'continue_sin_avance'
        $o.Decision.GlobalStatus | Should Be 'RUNNING'
        $o.Decision.ShouldContinue | Should Be $true
        $o.Decision.Reason | Should Be 'la sesion emitio CONTINUE sin avanzar el checkpoint; reintento 1 de 1'
        $o.CountsAsNoProgress | Should Be $true
        $o.IsRetry | Should Be $true
        $o.PlanStatusForEvent | Should Be 'CONTINUE'
    }

    It 'fila 3: CONTINUE sin avance con reintentos agotados -> BLOCKED' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $false -ErrTailLines @() -NoProgressStreak 1 -NoProgressRetries 1
        $o.Cause | Should Be 'continue_sin_avance'
        $o.Decision.GlobalStatus | Should Be 'BLOCKED'
        $o.Decision.ShouldContinue | Should Be $false
        $o.Decision.Reason | Should Be 'la sesion emitio CONTINUE sin avanzar el checkpoint en 2 sesiones seguidas; revisa el log de la ultima sesion'
        $o.CountsAsNoProgress | Should Be $true
        $o.IsRetry | Should Be $false
    }

    It 'fila 4: CONTINUE con avance -> como hoy, sin causa' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $true -ErrTailLines @() -NoProgressStreak 1 -NoProgressRetries 1
        $o.Cause | Should BeNullOrEmpty
        $o.Decision.GlobalStatus | Should Be 'RUNNING'
        $o.Decision.ShouldContinue | Should Be $true
        $o.CountsAsNoProgress | Should Be $false
        $o.IsRetry | Should Be $false
    }

    It 'fila 4: CONTINUE con avance no medible (Advanced nulo) -> como hoy, sin causa' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $null
        $o.Cause | Should BeNullOrEmpty
        $o.Decision.GlobalStatus | Should Be 'RUNNING'
        $o.IsRetry | Should Be $false
    }

    It 'fila 5: sin marca pero con avance -> sin_marca_con_avance, continua' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('Nivel 2 cerrado y checkpoint actualizado.') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $true -ErrTailLines @() -NoProgressStreak 0 -NoProgressRetries 1
        $o.Cause | Should Be 'sin_marca_con_avance'
        $o.Decision.GlobalStatus | Should Be 'RUNNING'
        $o.Decision.ShouldContinue | Should Be $true
        $o.Decision.Reason | Should Be 'sin marca PLAN_STATUS, pero el checkpoint avanzo: se continua'
        $o.PlanStatusForEvent | Should BeNullOrEmpty
        $o.CountsAsNoProgress | Should Be $false
        $o.IsRetry | Should Be $false
    }

    It 'fila 6: sin marca y avance no medible -> motivo actual, sin causa' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('texto') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $null -ErrTailLines @($bgErr)
        $o.Cause | Should BeNullOrEmpty
        $o.Decision.GlobalStatus | Should Be 'FAILED'
        $o.Decision.Reason | Should Be 'no emitio marca PLAN_STATUS reconocible'
    }

    It 'fila 7: sin marca, sin avance y techo de background en err.log -> truncada_background, FAILED sin reintento' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('El implementer de Task 10 corre en segundo plano. Espero su notificacion?') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $false -ErrTailLines @('aviso previo', $bgErr) -NoProgressStreak 0 -NoProgressRetries 1
        $o.Cause | Should Be 'truncada_background'
        $o.Decision.GlobalStatus | Should Be 'FAILED'
        $o.Decision.ShouldContinue | Should Be $false
        $o.Decision.Reason | Should Be 'sesion truncada por el techo de background de claude -p (err.log: "Background tasks still running"); relanza con -BackgroundWaitCeilingMs 0'
        $o.IsRetry | Should Be $false
    }

    It 'fila 8: sin marca, sin avance y ultima linea pregunta -> pregunta_sin_marca, BLOCKED' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('Analisis del nivel.', 'Prefieres que el endpoint devuelva 404 o 410?') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $false -ErrTailLines @() -NoProgressStreak 0 -NoProgressRetries 1
        $o.Cause | Should Be 'pregunta_sin_marca'
        $o.Decision.GlobalStatus | Should Be 'BLOCKED'
        $o.Decision.ShouldContinue | Should Be $false
        $o.Decision.Reason | Should Be 'la sesion termino con una pregunta en vez de PLAN_STATUS: Prefieres que el endpoint devuelva 404 o 410?'
        $o.IsRetry | Should Be $false
    }

    It 'fila 8: la pregunta se recorta a 200 caracteres en el motivo' {
        $long = ('x' * 250) + '?'
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @($long) -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $false -ErrTailLines @() -NoProgressStreak 0 -NoProgressRetries 1
        $o.Decision.Reason | Should Be ('la sesion termino con una pregunta en vez de PLAN_STATUS: ' + ('x' * 200))
    }

    It 'fila 9: sin marca, sin avance y sin otra senal con reintento disponible -> indeterminado, reintenta' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('Trabajo en curso.') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $false -ErrTailLines @() -NoProgressStreak 0 -NoProgressRetries 1
        $o.Cause | Should Be 'indeterminado'
        $o.Decision.GlobalStatus | Should Be 'RUNNING'
        $o.Decision.ShouldContinue | Should Be $true
        $o.Decision.Reason | Should Be 'sin marca PLAN_STATUS ni avance del checkpoint; reintento 1 de 1'
        $o.CountsAsNoProgress | Should Be $true
        $o.IsRetry | Should Be $true
    }

    It 'fila 10: indeterminado con reintentos agotados -> FAILED' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @() -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $false -ErrTailLines $null -NoProgressStreak 1 -NoProgressRetries 1
        $o.Cause | Should Be 'indeterminado'
        $o.Decision.GlobalStatus | Should Be 'FAILED'
        $o.Decision.ShouldContinue | Should Be $false
        $o.Decision.Reason | Should Be 'sin marca PLAN_STATUS ni avance del checkpoint en 2 sesiones seguidas'
        $o.CountsAsNoProgress | Should Be $true
        $o.IsRetry | Should Be $false
    }

    It 'NoProgressRetries 0: la primera sesion sin avance ya para' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'continue' -FinalReviewMarkerExists $false -MarkerRelativePath $null -Advanced $false -ErrTailLines @() -NoProgressStreak 0 -NoProgressRetries 0
        $o.Decision.GlobalStatus | Should Be 'BLOCKED'
        $o.Decision.Reason | Should Be 'la sesion emitio CONTINUE sin avanzar el checkpoint en 1 sesiones seguidas; revisa el log de la ultima sesion'
        $o.IsRetry | Should Be $false
    }

    It 'close + CONTINUE sin marcador (Advanced falso) -> continue_sin_avance con reintento' {
        $o = Resolve-SessionOutcome -ExitCode 0 -TailLines @('PLAN_STATUS: CONTINUE') -Mode 'close' -FinalReviewMarkerExists $false -MarkerRelativePath 'docs\superpowers\plans\.final-review-p.md' -Advanced $false -ErrTailLines @() -NoProgressStreak 0 -NoProgressRetries 1
        $o.Cause | Should Be 'continue_sin_avance'
        $o.IsRetry | Should Be $true
        $o.CloseGateApplied | Should Be $false
    }
}
