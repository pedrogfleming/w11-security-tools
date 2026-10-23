# ==========================================
# SCRIPT: Radar de Seguridad Diario
# Revisiones: Puerto SSH, puertos expuestos, tareas nuevas
# ==========================================
param(
    [switch]$AprobarTareas
)

$eventoLog = "Seguridad-Port22"
$logType   = "Application"
$refTareas = Join-Path $PSScriptRoot "tareas_baseline.txt"
$alertas   = @()

# Procesos de Windows que pueden escuchar en la red sin ser sospechosos.
# Si usas Hyper-V / WSL2 / Docker, agrega 'vmms' a esta lista.
$procesosPermitidos = @(
    'svchost','lsass','System','smss','csrss','services','wininit','winlogon',
    'dwm','RuntimeBroker','SearchIndexer','MsMpEng','NisSrv','vmms'
)

function Write-LogSeguridad {
    param([string]$Mensaje, [string]$Tipo = 'Information', [int]$Id = 1000)
    try {
        Write-EventLog -LogName $logType -Source $eventoLog -EventId $Id `
            -EntryType $Tipo -Message $Mensaje -ErrorAction Stop
    } catch {
        Write-Warning "No se pudo escribir en el Event Log: $($_.Exception.Message)"
    }
}

# --- Revision 1: Puerto 22 (SSH) ---
$sshPuerto   = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
$sshServicio = Get-Service -Name sshd -ErrorAction SilentlyContinue

if ($sshPuerto) {
    $alertas += "CRITICO: Puerto 22 (SSH) ABIERTO y escuchando."
}
if ($sshServicio) {
    $alertas += "ADVERTENCIA: servicio sshd instalado (estado: $($sshServicio.Status)). El puerto 22 podria abrirse."
}

# --- Revision 2: Puertos escuchando en 0.0.0.0 / :: (expuestos a la red) ---
$puertosPublicos = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalAddress -in @('0.0.0.0','::') } |
    ForEach-Object {
        $proc   = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        $nombre = if ($proc) { $proc.Name } else { 'desconocido' }
        [PSCustomObject]@{ Puerto = $_.LocalPort; Proceso = $nombre }
    } |
    Where-Object { $_.Proceso -notin $procesosPermitidos } |
    Sort-Object Puerto -Unique

if ($puertosPublicos) {
    $detalle = ($puertosPublicos | ForEach-Object { "$($_.Puerto) ($($_.Proceso))" }) -join ", "
    $alertas += "ADVERTENCIA: Puertos expuestos por procesos no habituales: $detalle"
}

# --- Revision 3: Tareas programadas nuevas (comparadas con linea base) ---
$tareasActuales = Get-ScheduledTask |
    ForEach-Object { "$($_.TaskPath)$($_.TaskName)" } |
    Sort-Object -Unique

$tareasNuevas = @()
if (Test-Path $refTareas) {
    $tareasPrevias = Get-Content $refTareas | Where-Object { $_.Trim() } | Sort-Object -Unique
    $tareasNuevas = Compare-Object -ReferenceObject $tareasPrevias -DifferenceObject $tareasActuales |
        Where-Object { $_.SideIndicator -eq '=>' } |
        Select-Object -ExpandProperty InputObject
} else {
    Write-Output "PRIMERA EJECUCION: linea base de tareas creada en $refTareas"
}

if ($tareasNuevas.Count -gt 0 -and -not $AprobarTareas) {
    $alertas += "REVISION: Tareas programadas nuevas:`n  - " + ($tareasNuevas -join "`n  - ")
}

# La linea base solo se actualiza si no hay tareas nuevas (o si las apruebas).
# Asi la alerta se repite todos los dias hasta que tomes accion.
if ($AprobarTareas -or $tareasNuevas.Count -eq 0) {
    $tareasActuales | Set-Content -Path $refTareas -Encoding UTF8
}

# --- Reporte final ---
if ($alertas.Count -gt 0) {
    $mensaje = ($alertas -join "`n")

    Write-LogSeguridad -Mensaje $mensaje -Tipo Error -Id 1001
    Write-Output "ALERTAS GENERADAS:"
    $alertas | ForEach-Object { Write-Output "  - $_" }

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $mensaje + "`n`nRevise inmediatamente.",
        "RADAR DE SEGURIDAD",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
} else {
    Write-LogSeguridad -Mensaje "Radar OK: sin puerto 22, sin puertos inusuales, sin tareas nuevas." -Tipo Information -Id 1000
    Write-Output "RADAR OK: Sin amenazas detectadas."
}