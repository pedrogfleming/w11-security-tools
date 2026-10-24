# ==========================================
# Radar.config.psd1
# Configuracion del Radar de Seguridad.
# Si el archivo no existe, el script usa estos mismos valores.
# ==========================================
@{
    # $true  = solo los hallazgos CRITICOS abren popup (recomendado, evita fatiga)
    # $false = los AVISOS tambien abren popup
    PopupSoloCritico = $true

    Umbrales = @{
        # Dias de antiguedad maxima de las firmas de Defender antes de avisar
        DiasFirmaDefender = 4
    }

    # Estados que aceptas de forma permanente y no deben alertar como criticos.
    # Poner en $true si vos usas esa funcion a proposito.
    Aceptados = @{
        RDP   = $false
        WinRM = $false
    }

    # Procesos que pueden escuchar en la red sin generar aviso
    ProcesosPermitidos = @(
        'svchost','lsass','System','smss','csrss','services','wininit','winlogon',
        'dwm','RuntimeBroker','SearchIndexer','MsMpEng','NisSrv','vmms'
    )

    Ignorar = @{
        # Nombres tecnicos (propiedad Name) de reglas de firewall que no queres vigilar
        ReglasFirewall = @()
    }
}
