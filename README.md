# Radar de Seguridad - Windows 11

Monitoreo diario y automatico de la superficie de ataque basica de un equipo Windows 11:

1. **Puerto 22 (SSH)** abierto o servicio `sshd` instalado.
2. **Puertos escuchando en la red** (`0.0.0.0` / `::`) abiertos por procesos que no son del sistema.
3. **Tareas programadas nuevas** respecto a una linea base conocida (persistencia tipica de malware).

Cuando algo cambia: **popup en pantalla** + **evento en el Visor de Eventos**.

> El script **detecta y avisa**, no bloquea. La mitigacion (cerrar puerto, deshabilitar servicio, borrar tarea) la haces tu con los comandos de la seccion [Que hacer cuando salta una alerta](#5-que-hacer-cuando-salta-una-alerta).

---

## 0. Resumen: orden de instalacion

> **Camino rapido (recomendado):** copia `Check-Port22.ps1` + `Install-Radar.ps1` a una carpeta y ejecuta
> `powershell -ExecutionPolicy Bypass -File .\Install-Radar.ps1`
>
> Ese unico comando hace los pasos 2 a 5 (fuente del Event Log + tarea + primera corrida + verificacion) y se auto-eleva pidiendo UAC. La tabla y los pasos manuales de abajo son el equivalente detallado, utiles para entender o para reparar a mano.

| # | Paso | Necesita Administrador |
|---|------|------------------------|
| 1 | Crear `C:\Scripts` y copiar `Check-Port22.ps1` (UTF-8 con BOM) | No |
| 2 | Registrar la fuente del Event Log `Seguridad-Port22` | **Si** (solo una vez) |
| 3 | Probar el script a mano | No |
| 4 | Crear la Tarea Programada | **Si** |
| 5 | Verificar de punta a punta | No |
| 6 | (Opcional) Endurecer firewall / servicios | **Si** |

Si te salteas el paso 2, el script igual funciona pero **no deja registro** en el Visor de Eventos (avisa por consola y sigue).

---

## 1. Requisitos

- Windows 11 (funciona en Windows 10 1809+).
- Windows PowerShell 5.1 (el que viene con Windows). No requiere PowerShell 7.
- Permisos de Administrador **solo** para: registrar la fuente del Event Log y crear la tarea programada.
- El usuario que ejecuta el script debe tener **sesion iniciada** para ver el popup (la tarea corre en modo interactivo).

---

## 2. Archivos

| Archivo | Que es | Se regenera |
|---------|--------|-------------|
| `C:\Scripts\Check-Port22.ps1` | Script principal (radar). Es el unico imprescindible. | No |
| `C:\Scripts\Install-Radar.ps1` | Instalador/desinstalador automatico. | No |
| `C:\Scripts\README.md` | Este documento. | No |
| `C:\Scripts\tareas_baseline.txt` | Lista de tareas programadas "conocidas". La crea el script en la **primera ejecucion**. | Si (en cada ejecucion sin novedades) |
| `C:\Scripts\Firewall.md` | Comando opcional de endurecimiento del firewall. | No |
| `C:\Scripts\Tareas_Referencia.txt` | **Obsoleto** (version vieja del control de tareas). Se puede borrar. | No |

> No edites `tareas_baseline.txt` a mano salvo que quieras reiniciar el control de tareas (ver [Mantenimiento](#8-mantenimiento)).

---

## 3. Instalacion paso a paso

### 3.0 - Instalacion automatica (recomendada)

Copia a una carpeta `Check-Port22.ps1` e `Install-Radar.ps1`, y ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Radar.ps1
```

El instalador:

1. Se auto-eleva (UAC) si no esta como Administrador.
2. Verifica que exista `Check-Port22.ps1` al lado.
3. Registra la fuente `Seguridad-Port22` (si ya existe, no la toca).
4. Crea o reemplaza la tarea programada (diaria 00:00 + al iniciar sesion, `Highest`, `Interactive`).
5. Ejecuta el radar por primera vez (crea `tareas_baseline.txt`).
6. Verifica: `LastTaskResult = 0` y evento reciente en el Visor.

Es **idempotente**: se puede volver a correr para reparar o reconfigurar sin duplicar nada.

Opciones:

| Parametro | Default | Para que |
|-----------|---------|----------|
| `-DailyAt "11:00PM"` | `12:00AM` | Cambiar la hora de la corrida diaria. |
| `-TaskName "..."` | `Seguridad - Revision Puerto SSH` | Otro nombre de tarea. |
| `-ScriptPath "..."` | `Check-Port22.ps1` junto al instalador | Script en otra ruta. |
| `-NoFirstRun` | (apagado) | Instalar sin ejecutar ni crear la linea base. |
| `-Uninstall` | (apagado) | Quitar la tarea y la fuente del Event Log. |

```powershell
# Ejemplos
.\Install-Radar.ps1 -DailyAt "11:00PM"
.\Install-Radar.ps1 -Uninstall
```

> Si no ves la ventana del instalador, es porque se relanzo elevado en otra consola: acepta el UAC y mira esa ventana.

Los pasos manuales de abajo son el equivalente detallado (utiles para entender que hace cada cosa o para reparar a mano).

### Paso 1 - Crear la carpeta y el script

Abre PowerShell normal (no hace falta admin) y ejecuta:

```powershell
New-Item -ItemType Directory -Force -Path "C:\Scripts" | Out-Null
```

Copia `Check-Port22.ps1` a `C:\Scripts\`. Si lo creas a mano, **debe guardarse en UTF-8 con BOM**, si no PowerShell falla con errores de parseo por los acentos.

En VS Code: clic en la codificacion de la barra inferior derecha -> **Save with Encoding** -> **UTF-8 with BOM**.
En Notepad: **Guardar como** -> Codificacion: **UTF-8 con BOM**.

Verifica que quedo bien (debe imprimir `239 187 191`):

```powershell
$b = [System.IO.File]::ReadAllBytes("C:\Scripts\Check-Port22.ps1")
"{0} {1} {2}" -f $b[0], $b[1], $b[2]
```

> El script no tiene acentos a proposito, pero el BOM evita problemas si mas adelante lo editas.

### Paso 2 - Registrar la fuente del Event Log (Administrador)

**PowerShell como Administrador**, una sola vez por equipo:

```powershell
if (-not (Get-EventLog -LogName Application -Source "Seguridad-Port22" -ErrorAction SilentlyContinue)) {
    New-EventLog -LogName Application -Source "Seguridad-Port22"
    Write-Host "Fuente 'Seguridad-Port22' creada correctamente." -ForegroundColor Green
} else {
    Write-Host "La fuente del log ya existe." -ForegroundColor Yellow
}
```

Resultado esperado: `Fuente 'Seguridad-Port22' creada correctamente.`

> El nombre `Seguridad-Port22` se mantiene por compatibilidad con la tarea existente. El ID de evento y la fuente no cambian.

### Paso 3 - Primera ejecucion (crea la linea base)

PowerShell normal:

```powershell
& "C:\Scripts\Check-Port22.ps1"
```

Resultado esperado:

```text
PRIMERA EJECUCION: linea base de tareas creada en C:\Scripts\tareas_baseline.txt
RADAR OK: Sin amenazas detectadas.
```

Que paso:

- Se creo `tareas_baseline.txt` con **todas** las tareas actuales (incluidas las de Windows, AMD, Proton, etc.). No hay alerta de tareas en esta corrida: es intencional.
- Se registro un evento **ID 1000 (Information)** en el Visor de Eventos.

Si en este punto ves `ADVERTENCIA: Puertos expuestos por procesos no habituales`, mira [Puertos no habituales](#puertos-no-habituales).

### Paso 4 - Crear la Tarea Programada (Administrador)

**PowerShell como Administrador**:

```powershell
# Triggers: diario a medianoche + al iniciar sesion
$t1 = New-ScheduledTaskTrigger -Daily -At "12:00AM"
$t2 = New-ScheduledTaskTrigger -AtLogOn

# Accion: PowerShell oculto ejecutando el script
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"C:\Scripts\Check-Port22.ps1`""

# Settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

# Registrar
Register-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH" `
    -Action $action `
    -Trigger $t1, $t2 `
    -Settings $settings `
    -User "$env:USERDOMAIN\$env:USERNAME" `
    -RunLevel Highest `
    -Description "Radar diario: puerto SSH 22, puertos expuestos y tareas nuevas." `
    -Force
```

Detalles que importan:

| Parametro | Para que |
|-----------|----------|
| `-WindowStyle Hidden` | No abre consola negra; solo aparece el popup si hay alerta. |
| `-ExecutionPolicy Bypass` | Evita el error de "ejecucion de scripts deshabilitada". |
| `-User ...` + `RunLevel Highest` | Corre en tu sesion (necesario para que el popup sea visible) y con permisos suficientes para escribir el Event Log. |
| `-StartWhenAvailable` | Si a medianoche el equipo estaba apagado, corre al encender. |
| `-Force` | Sobrescribe la tarea si ya existia (reinstalacion). |

Verificar que quedo bien:

```powershell
Get-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH" |
    Select-Object TaskName, State

Get-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH" |
    Select-Object -ExpandProperty Triggers |
    Format-Table StartBoundary, DaysInterval, Enabled -AutoSize
```

Debe haber **dos** triggers: uno diario (00:00, cada 1 dia) y uno al inicio de sesion.

### Paso 5 - Verificacion de punta a punta

```powershell
Start-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH"
Start-Sleep -Seconds 5

Get-ScheduledTaskInfo -TaskName "Seguridad - Revision Puerto SSH" |
    Select-Object LastRunTime, LastTaskResult, NextRunTime

Get-EventLog -LogName Application -Source "Seguridad-Port22" -Newest 1 |
    Format-List TimeGenerated, EntryType, EventId, Message
```

- `LastTaskResult : 0` = la tarea corrio sin error.
- El evento mas reciente debe tener la hora actual.

### Paso 6 - (Opcional) Endurecimiento

El firewall ya viene bloqueando entradas no solicitadas. Si quieres forzarlo de forma explicita (contenido de `Firewall.md`):

```powershell
Set-NetFirewallProfile -Profile Domain,Public,Private `
    -DefaultInboundAction Block -DefaultOutboundAction Allow
```

Para revertir a los valores por defecto:

```powershell
Set-NetFirewallProfile -Profile Domain,Public,Private `
    -DefaultInboundAction NotConfigured -DefaultOutboundAction NotConfigured
```

Otras medidas opcionales aplicadas en este equipo (documentadas por si hay que reinstalar):

```powershell
# SMBv1 (protocolo viejo, vector de ransomware)
Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart

# Cola de impresion (si no se usan impresoras) - cierra los puertos dinamicos del spooler
Set-Service -Name Spooler -StartupType Disabled
Stop-Service -Name Spooler -Force

# Auditoria de PowerShell y creacion de procesos
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 1
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockInvocationLogging" -Value 1
auditpol /set /subcategory:"Process Creation" /success:enable
```

> Todas estas son **opcionales** para que el radar funcione. Ninguna es requisito.

---

## 4. Como funciona el script

Variables configurables al inicio de `Check-Port22.ps1`:

| Variable | Default | Significado |
|----------|---------|-------------|
| `$eventoLog` | `Seguridad-Port22` | Fuente del Event Log. |
| `$logType` | `Application` | Log de destino. |
| `$refTareas` | Join-Path $PSScriptRoot "tareas_baseline.txt" | Linea base de tareas. |
| `$procesosPermitidos` | lista | Procesos que pueden escuchar en la red sin alertar. |

### Revision 1 - Puerto 22

- Alerta **CRITICO** si algo escucha en el puerto 22.
- Alerta **ADVERTENCIA** si el servicio `sshd` existe aunque este detenido (senal de que alguien lo instalo).

### Revision 2 - Puertos expuestos

Lista todo lo que escucha en `0.0.0.0` o `::`, resuelve el proceso dueno y **descarta** los que estan en `$procesosPermitidos` (`svchost`, `lsass`, `System`, `dwm`, `vmms`, etc.).

Para sumar un proceso legitimo, edita la lista:

```powershell
$procesosPermitidos = @(
    'svchost','lsass','System','smss','csrss','services','wininit','winlogon',
    'dwm','RuntimeBroker','SearchIndexer','MsMpEng','NisSrv','vmms'
    #,'MiPrograma'
)
```

<b id="puertos-no-habituales"></b>

#### Puertos no habituales

Si aparece un puerto:

```powershell
$p = Get-NetTCPConnection -LocalPort <PUERTO> -State Listen
Get-Process -Id $p.OwningProcess | Select-Object Id, Name, Path
```

- Si es un programa que instalaste y necesitas -> agrega su proceso a `$procesosPermitidos`.
- Si no lo reconoces -> deshabilita el servicio (`Set-Service -Name <servicio> -StartupType Disabled; Stop-Service <servicio> -Force`) o desinstala el programa.

Casos tipicos ya vistos en este equipo:

| Puerto | Proceso | Que es | Decision |
|--------|---------|--------|----------|
| 2179 | `vmms` | Hyper-V Management | Deshabilitar si no se usa Hyper-V/WSL2/Docker; si se usa, esta en la lista blanca. |
| 49668 | `spoolsv` | Print Spooler | Se deshabilito el servicio (ya no aparece). |

### Revision 3 - Tareas nuevas (linea base)

- La **primera** ejecucion guarda todas las tareas actuales en `tareas_baseline.txt` y no alerta.
- Las siguientes ejecuciones comparan la lista actual contra la linea base y alertan **solo por las que no existian**.
- La linea base **solo se actualiza** si no hay tareas nuevas (o si corres con `-AprobarTareas`).

Consecuencia util: si aparece una tarea nueva, **te va a alertar todos los dias** hasta que la revises y la aceptes o la elimines.

```powershell
# Revisar y aceptar las tareas nuevas como conocidas
& "C:\Scripts\Check-Port22.ps1" -AprobarTareas
```

### Resultado y registro

| Resultado | Evento | ID | Consola |
|-----------|--------|----|---------|
| Todo normal | Information | 1000 | `RADAR OK: Sin amenazas detectadas.` |
| Hay alertas | Error | 1001 | `ALERTAS GENERADAS:` + detalle + popup |

---

## 5. Que hacer cuando salta una alerta

### "CRITICO: Puerto 22 (SSH) ABIERTO y escuchando"

```powershell
# Quien esta escuchando
Get-NetTCPConnection -LocalPort 22 -State Listen | Select-Object LocalAddress, OwningProcess
Get-Process -Id (Get-NetTCPConnection -LocalPort 22 -State Listen).OwningProcess | Select-Object Name, Path

# Si es OpenSSH Server: detener y deshabilitar
Stop-Service -Name sshd -Force
Set-Service  -Name sshd -StartupType Disabled

# Si no lo necesitas, desinstalarlo
Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object Name, State
Remove-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0"
```

### "ADVERTENCIA: servicio sshd instalado"

Alguien (o una herramienta) instalo el servidor SSH. Si no lo usas: `Remove-WindowsCapability` como arriba. Si lo usas: el aceptarlo es decision tuya, pero el radar seguira avisando (es intencional).

### "ADVERTENCIA: Puertos expuestos por procesos no habituales"

Ver [Puertos no habituales](#puertos-no-habituales).

### "REVISION: Tareas programadas nuevas"

```powershell
# Ver que hace la tarea (ruta completa, con barra inicial)
$t = Get-ScheduledTask -TaskPath "\" -TaskName "<NOMBRE>"

$t.Actions | Format-List Execute, Arguments
$t.Triggers | Format-List
$t.Principal | Format-List UserId, RunLevel
Export-ScheduledTask -TaskName "<NOMBRE>" -TaskPath "\"
```

- Si la reconoces (actualizacion de un programa, algo que instalaste): `& "C:\Scripts\Check-Port22.ps1" -AprobarTareas`.
- Si no la reconoces: deshabilitar y luego eliminar.

```powershell
Disable-ScheduledTask -TaskName "<NOMBRE>" -TaskPath "\"
Unregister-ScheduledTask -TaskName "<NOMBRE>" -TaskPath "\" -Confirm:$false
```

---

## 6. Comandos de uso diario

```powershell
# Ejecutar el radar ahora
& "C:\Scripts\Check-Port22.ps1"

# Ver el detalle de las ultimas corridas
Get-EventLog -LogName Application -Source "Seguridad-Port22" -Newest 10 |
    Format-Table TimeGenerated, EntryType, EventId, Message -AutoSize

# Solo alertas (ID 1001)
Get-EventLog -LogName Application -Source "Seguridad-Port22" -EntryType Error |
    Format-List TimeGenerated, Message

# Aceptar tareas nuevas como conocidas
& "C:\Scripts\Check-Port22.ps1" -AprobarTareas

# Forzar la tarea programada
Start-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH"

# Estado / ultima corrida / proxima corrida
Get-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH" | Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName "Seguridad - Revision Puerto SSH" |
    Select-Object LastRunTime, LastTaskResult, NextRunTime
```

### Probar que la alerta realmente funciona

Crea una tarea inofensiva, corre el radar y borrala (el popup debe mostrarla):

```powershell
Register-ScheduledTask -TaskName "PruebaRadar" `
    -Action (New-ScheduledTaskAction -Execute "notepad.exe") `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Force

& "C:\Scripts\Check-Port22.ps1"

Unregister-ScheduledTask -TaskName "PruebaRadar" -Confirm:$false
& "C:\Scripts\Check-Port22.ps1"   # vuelve a RADAR OK y refresca la linea base
```

---

## 7. Troubleshooting

| Sintoma | Causa | Solucion |
|---------|-------|----------|
| `Unexpected token 'PUERTO' in expression or statement` / caracteres raros (por ejemplo `SE DETECT?` en lugar de `SE DETECTO`) | Archivo guardado en ANSI/Windows-1252 | Guardar como **UTF-8 con BOM** (paso 1) y volver a probar. |
| `The source name "Seguridad-Port22" does not exist` | Falta el paso 2 | Registrar la fuente como Administrador (paso 2). |
| `The source was not found ... Inaccessible logs: Security, State` | Idem anterior | Idem. |
| El script dice `RADAR OK` pero no hay evento en el Visor | Falta la fuente del log | Paso 2. El script avisa con `Write-Warning` pero continua. |
| La tarea figura como ejecutada pero no hay popup | El popup solo aparece en sesion interactiva desbloqueada | Probar a mano; confirmar `LogonType Interactive` y `RunLevel Highest`; revisar que la sesion este desbloqueada. |
| La tarea no corre a la hora esperada | Equipo apagado/suspendido | `StartWhenAvailable` ya lo cubre al encender. Verificar `NextRunTime`. |
| `cannot be loaded because running scripts is disabled` | ExecutionPolicy | La tarea ya usa `-ExecutionPolicy Bypass`. Si ejecutas a mano: `powershell -ExecutionPolicy Bypass -File "C:\Scripts\Check-Port22.ps1"`. |
| Alerta de tareas **todos los dias** por lo mismo | Hay tareas nuevas sin revisar (por diseno) | Revisar y luego `-AprobarTareas`, o eliminar la tarea. |
| Alerta de puertos con procesos conocidos | Proceso fuera de la lista blanca | Agregarlo a `$procesosPermitidos`. |
| `PRIMERA EJECUCION` aparece de nuevo | Se borro `tareas_baseline.txt` | Es normal: se recrea sin alertar. Si fue accidental, revisa las tareas actuales antes de confiar en la nueva base. |
| `Register-ScheduledTask : ... ya existe` | Tarea duplicada | Volver a correr el comando del paso 4 o `Install-Radar.ps1` (usa `-Force`). |
| `Install-Radar.ps1` parece no hacer nada o la consola se cierra | Se relanzo elevado en **otra** ventana | Aceptar el UAC y mirar la ventana nueva (la original termina enseguida). |

---

## 8. Mantenimiento

### Cambiar la hora de ejecucion

```powershell
$t1 = New-ScheduledTaskTrigger -Daily -At "11:00PM"   # hora deseada
$t2 = New-ScheduledTaskTrigger -AtLogOn

Set-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH" -Trigger $t1, $t2
```

### Pausar sin borrar

```powershell
Disable-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH"
Enable-ScheduledTask  -TaskName "Seguridad - Revision Puerto SSH"
```

### Reiniciar el control de tareas (nueva linea base)

Solo cuando estas seguro de que el estado actual es limpio:

```powershell
Remove-Item "C:\Scripts\tareas_baseline.txt"
& "C:\Scripts\Check-Port22.ps1"
```

### Desinstalacion completa

Automatica:

```powershell
.\Install-Radar.ps1 -Uninstall
```

Manual:

```powershell
# 1. Tarea programada
Unregister-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH" -Confirm:$false

# 2. Fuente del Event Log (Administrador)
Remove-EventLog -Source "Seguridad-Port22"

# 3. Archivos
Remove-Item "C:\Scripts\Check-Port22.ps1"
Remove-Item "C:\Scripts\tareas_baseline.txt"
Remove-Item "C:\Scripts\Tareas_Referencia.txt" -ErrorAction SilentlyContinue
```

---

## 9. Alcance y limitaciones

- **Detecta, no previene.** No bloquea puertos ni mata procesos.
- El popup requiere sesion iniciada y desbloqueada. Si el equipo esta apagado, la revision diaria se recupera con `StartWhenAvailable` al encender.
- La revision es **por instantanea**: si alguien abre el puerto 22 y lo cierra entre dos corridas, no se detecta. Para cobertura continua haria falta un evento/agente, no una tarea programada.
- Un atacante con privilegios de Administrador puede deshabilitar la tarea, borrar `tareas_baseline.txt` o la fuente del Event Log. Esto es un control de higiene, no un EDR.
- No reemplaza antivirus, actualizaciones ni copias de seguridad.

---

## 10. Checklist final de instalacion

- [ ] `C:\Scripts\Check-Port22.ps1` existe y empieza con BOM (`239 187 191`).
- [ ] `Install-Radar.ps1` corrido sin errores (o los pasos manuales 2 a 5 completados).
- [ ] Fuente `Seguridad-Port22` registrada en el log `Application`.
- [ ] Primera ejecucion manual: creo `tareas_baseline.txt` y mostro `RADAR OK`.
- [ ] Tarea `Seguridad - Revision Puerto SSH` creada con **dos** triggers (diaria 00:00 + al iniciar sesion).
- [ ] `RunLevel = Highest` y `LogonType = Interactive`.
- [ ] `Start-ScheduledTask` deja `LastTaskResult = 0` y un evento nuevo en el Visor.
- [ ] Prueba de alerta con `PruebaRadar` mostro el popup (y luego se borro).

---

## Apendice - Script de referencia

> Fuente de verdad: `C:\Scripts\Check-Port22.ps1`. Si difieren, gana el archivo.

```powershell
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
```
