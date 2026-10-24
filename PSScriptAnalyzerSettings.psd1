# ==========================================
# PSScriptAnalyzerSettings.psd1
# Reglas que se excluyen a proposito en este proyecto.
# Los errores (Severity Error) NO se excluyen: el CI falla con ellos.
# ==========================================
@{
    # Write-Host es intencional en el instalador: es una herramienta interactiva
    # y queremos color/legibilidad, no salida capturable.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'

        # Nombres de funciones internas del radar (no son cmdlets publicos)
        'PSUseSingularNouns'

        # New-Hallazgo solo construye un objeto en memoria, no cambia estado
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
