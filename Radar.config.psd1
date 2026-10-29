# ==========================================
# Radar.config.psd1
# Configuracion del Radar de Seguridad.
# Si el archivo no existe, el script usa estos mismos valores.
# ==========================================
@{
    # $true  = solo los hallazgos CRITICOS abren popup (recomendado, evita fatiga)
    # $false = los AVISOS tambien abren popup
    PopupSoloCritico = $true

    # Cuantos informes se conservan en logs\ SIN comprimir. Los mas viejos NO se
    # borran: se archivan en logs\archivo\radar-<AAAA-MM>.zip (guardado eterno).
    # 0 = no archivar nunca (deja todos los .log sueltos).
    RetencionInformes = 60

    # $true  = los informes viejos se comprimen y se guardan para siempre
    # $false = los informes viejos se borran (comportamiento anterior)
    ArchivarInformes = $true

    # Programa con el que el popup abre el informe al hacer click en el path.
    # 'notepad.exe' = Notepad (siempre disponible; recomendado)
    # ''            = aplicacion asociada de Windows (ojo: .log no siempre tiene)
    # 'code.cmd'    = VS Code, si esta en el PATH
    AbrirDetalleCon = 'notepad.exe'

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
        'dwm','RuntimeBroker','SearchIndexer','MsMpEng','NisSrv','vmms','steam'
    )

    Ignorar = @{
        # Patrones (con comodines * y ?) sobre Name o DisplayName de la regla.
        # Sirven para silenciar reglas conocidas y ruidosas, por ejemplo:
        #   'Microsoft Edge*', 'Brave*', 'Firefox*', '*mDNS*'
        # Por defecto vacio: las reglas de navegadores ya no generan falsos
        # positivos porque el script normaliza los GUIDs del Name.
        ReglasFirewall = @()

        # Patrones (con comodines) sobre el TaskPath de tareas programadas.
        # SoftLanding es un componente de Windows Update que recrea sus tareas
        # con GUIDs nuevos en cada ciclo de actualizacion.
        TareasPath = @('\SoftLanding\*')
    }
}
