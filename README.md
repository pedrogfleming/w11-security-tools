# Radar de Seguridad - Windows 11 (fase 1)

Monitoreo diario de la superficie de ataque de un equipo Windows 11:

1. **Puerto 22 (SSH)** abierto o servicio `sshd` instalado.
2. **Puertos escuchando en la red** (`0.0.0.0` / `::`) por procesos no habituales.
3. **Tareas programadas nuevas** respecto a una linea base.
4. **Microsoft Defender**: proteccion en tiempo real, firmas, manipulacion, amenazas activas y exclusiones.
5. **Firewall**: perfiles apagados o permisivos, y reglas de entrada nuevas expuestas.
6. **Acceso remoto**: RDP y WinRM habilitados sin querer.
7. **Identidad**: administradores/usuarios locales nuevos, cuentas integradas, autologon, UAC y WDigest.

Cuando algo cambia: **informe en `logs\`**, **evento en el Visor** y, si es **critico**, **popup en pantalla** con el detalle y un link al informe.

> El script **detecta y avisa**, no bloquea. La accion correctiva es tuya (seccion 5).
> Fase 1 cubre Defender, Firewall, RDP/WinRM e Identidad. Persistencia avanzada, red y eventos (4625/1102) quedan para la fase 2.

---

## 0. Resumen: orden de instalacion

> **Camino rapido (recomendado):** copia `Check-Port22.ps1` + `Install-Radar.ps1` (+ `Radar.config.psd1`) a una carpeta y ejecuta
> `powershell -ExecutionPolicy Bypass -File .\Install-Radar.ps1`
>
> Ese unico comando hace los pasos 2 a 5 (fuente del Event Log + tarea + primera corrida + verificacion) y se auto-eleva pidiendo UAC.

| # | Paso | Necesita Administrador |
|---|------|------------------------|
| 1 | Crear la carpeta y copiar los archivos (UTF-8 con BOM) | No |
| 2 | Registrar la fuente del Event Log `Seguridad-Port22` | **Si** (solo una vez) |
| 3 | Probar el script a mano (`-SinPopup`) | No* |
| 4 | Crear la Tarea Programada | **Si** |
| 5 | Verificar de punta a punta | No |
| 6 | (Opcional) Endurecer firewall / servicios | **Si** |

\* Sin Administrador el script funciona, pero **omite los chequeos con linea base** (tareas, exclusiones de Defender, reglas de firewall, identidad) y las amenazas activas, porque la vista del sistema cambia con el privilegio. Lo avisa por consola. La tarea programada corre elevada, asi que el chequeo completo es automatico.

---

## 1. Requisitos

- Windows 11 (tambien Windows 10 1809+).
- Windows PowerShell 5.1 (el que viene con Windows). No requiere PowerShell 7.
- Administrador para: registrar la fuente del Event Log, crear la tarea programada y ejecutar los chequeos con linea base.
- Los chequeos con linea base (tareas, exclusiones de Defender, reglas de firewall, identidad) y las amenazas activas **solo corren elevados**, igual que la tarea programada. Sin Administrador el script hace solo los chequeos de estado y lo avisa por consola.
- El usuario debe tener **sesion iniciada** para ver el popup (la tarea corre en modo interactivo).

---

## 2. Archivos

| Archivo | Que es | Se regenera |
|---------|--------|-------------|
| `Check-Port22.ps1` | Radar principal (los 7 chequeos). | No |
| `Install-Radar.ps1` | Instalador/desinstalador automatico. | No |
| `Radar.config.psd1` | Configuracion: umbrales, estados aceptados, whitelists. | No |
| `README.md` | Este documento. | No |
| `.github/` | Workflow de CI y rulesets de proteccion de `main`. | No |
| `tests/` | Tests Pester de las funciones de linea base. | No |
| `PSScriptAnalyzerSettings.psd1` | Reglas excluidas del lint (a proposito). | No |
| `LICENSE` | Licencia MIT. | No |
| `.gitattributes` | Normalizacion de line endings (LF en repo, CRLF en scripts). | No |
| `baseline\*.json` | Lineas base por chequeo (se crean solas, con claves normalizadas). | Si |
| `logs\radar-*.log` | Informe de cada corrida (lo abre el popup con un click). | Si |
| `Firewall.md` | Comando opcional de endurecimiento. | No |
| `Tareas_Referencia.txt` | **Obsoleto** (version vieja). Se puede borrar. | No |

> `tareas_baseline.txt` (formato legacy) ya no existe: se migro a `baseline\tareas.json` y el script lo recrea solo si alguien lo vuelve a dejar.

> Las rutas son relativas al script (`$PSScriptRoot`), asi que el proyecto funciona en cualquier carpeta.

---

## 3. Instalacion

### 3.0 - Instalacion automatica (recomendada)

Copia `Check-Port22.ps1`, `Install-Radar.ps1` y `Radar.config.psd1` a una carpeta y ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Radar.ps1
```

El instalador:

1. Se auto-eleva (UAC) si no esta como Administrador.
2. Verifica que exista `Check-Port22.ps1`.
3. Registra la fuente `Seguridad-Port22` (si ya existe, no la toca).
4. Crea o reemplaza la tarea programada (diaria 00:00 + al iniciar sesion, `Highest`, `Interactive`).
5. Ejecuta el radar por primera vez (crea todas las lineas base).
6. Verifica: `LastTaskResult = 0` y evento reciente en el Visor.

Es **idempotente**: se puede volver a correr para reparar o reconfigurar sin duplicar nada.

| Parametro | Default | Para que |
|-----------|---------|----------|
| `-DailyAt "11:00PM"` | `12:00AM` | Cambiar la hora de la corrida diaria. |
| `-TaskName "..."` | `Seguridad - Revision Puerto SSH` | Otro nombre de tarea. |
| `-ScriptPath "..."` | `Check-Port22.ps1` junto al instalador | Script en otra ruta. |
| `-NoFirstRun` | (apagado) | Instalar sin ejecutar ni crear lineas base. |
| `-Uninstall` | (apagado) | Quitar tarea, fuente de Event Log y lineas base. |

```powershell
.\Install-Radar.ps1 -DailyAt "11:00PM"
.\Install-Radar.ps1 -Uninstall
```

> Si no ves la ventana del instalador, es porque se relanzo elevado en otra consola: acepta el UAC y mira esa ventana.

### Idempotencia y reinstalacion

Se puede correr las veces que quieras: el estado final es el mismo.

| Operacion | Comportamiento |
|-----------|----------------|
| Fuente `Seguridad-Port22` | Si ya existe en `Application`, no se toca. Si existiera en otro log, aborta con mensaje. |
| Tarea programada | Se reemplaza con `-Force` (mismo nombre, sin duplicados). |
| Lineas base | Se conservan si existen; se crean si faltan. |
| Tarea **pausada** | Se reinstala y se **deja pausada**; no se ejecuta ni se verifica. |
| Tarea corriendo | Se detiene antes de reinstalar. |
| Eventos | Cada corrida agrega 2 eventos (ejecucion manual + prueba de la tarea). Es normal. |
| Historial de la tarea | `-Force` lo reinicia; la verificacion lo vuelve a poblar. |
| Cambiar `-TaskName` | Crea otra tarea; la anterior queda y hay que borrarla a mano. |
| `-Uninstall` repetido | La segunda vez avisa que ya no existe; no falla. |

Lo unico que **no** es idempotente es el tiempo: cada ejecucion agrega eventos al Visor, deja un informe en `logs\` y, si hay criticos, muestra popup. Los pasos manuales que siguen son el equivalente detallado del instalador (utiles para entender o reparar a mano).

### Paso 1 - Crear la carpeta y copiar los archivos

```powershell
New-Item -ItemType Directory -Force -Path "C:\Scripts" | Out-Null
```

Copia `Check-Port22.ps1` a `C:\Scripts\`. Si lo creas a mano, **debe guardarse en UTF-8 con BOM**:

```powershell
$b = [System.IO.File]::ReadAllBytes("C:\Scripts\Check-Port22.ps1")
"{0} {1} {2}" -f $b[0], $b[1], $b[2]   # debe imprimir 239 187 191
```

En VS Code: clic en la codificacion (barra inferior) -> **Save with Encoding** -> **UTF-8 with BOM**.
En Notepad: **Guardar como** -> Codificacion: **UTF-8 con BOM**.

### Paso 2 - Registrar la fuente del Event Log (Administrador)

```powershell
if (-not (Get-EventLog -LogName Application -Source "Seguridad-Port22" -ErrorAction SilentlyContinue)) {
    New-EventLog -LogName Application -Source "Seguridad-Port22"
    Write-Host "Fuente 'Seguridad-Port22' creada correctamente." -ForegroundColor Green
} else {
    Write-Host "La fuente del log ya existe." -ForegroundColor Yellow
}
```

### Paso 3 - Primera ejecucion (Administrador)

Con PowerShell **como Administrador** (igual que la tarea, para que las lineas base se creen con la vista completa):

```powershell
& "C:\Scripts\Check-Port22.ps1" -SinPopup
```

Resultado esperado en un equipo limpio (la primera vez):

```text
[i] Tareas: Linea base creada (262 tareas).
[i] Defender: Linea base de exclusiones creada (0 entradas).
[i] Firewall: Linea base de reglas de entrada creada (229 reglas).
[i] Identidad: Linea base de administradores creada (2 miembros).
[i] Identidad: Linea base de usuarios locales creada (5 cuentas).
RADAR OK: sin amenazas detectadas (5 informativos).
```

Los mensajes `[i] ... Linea base creada` son normales y no alertan: es el punto de partida.
Si en cambio ves `[i] Sin Administrador: se omiten los chequeos con linea base...`, la consola no esta elevada: los chequeos de estado se hicieron, pero no se crearon lineas base.

> **Regla de oro:** las lineas base se crean y actualizan **solo** en corridas elevadas. Correr el script sin Administrador nunca las modifica (asi una vista parcial no puede generar falsas alertas despues).

### Paso 4 - Crear la Tarea Programada (Administrador)

```powershell
$t1 = New-ScheduledTaskTrigger -Daily -At "12:00AM"
$t2 = New-ScheduledTaskTrigger -AtLogOn

$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"C:\Scripts\Check-Port22.ps1`""

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 60)

Register-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH" `
    -Action $action `
    -Trigger $t1, $t2 `
    -Settings $settings `
    -User "$env:USERDOMAIN\$env:USERNAME" `
    -RunLevel Highest `
    -Description "Radar diario: SSH, puertos, tareas, Defender, firewall, RDP/WinRM e identidad." `
    -Force
```

| Parametro | Para que |
|-----------|----------|
| `-WindowStyle Hidden` | No abre consola negra; solo aparece el popup si hay criticals. |
| `-NonInteractive` | Si algun comando pidiera confirmacion, falla en vez de dejar la tarea oculta colgada esperando. |
| `-ExecutionPolicy Bypass` | Evita "ejecucion de scripts deshabilitada". |
| `-User ...` + `RunLevel Highest` | Corre en tu sesion (popup visible) y con permisos para el Event Log y las exclusiones de Defender. |
| `-StartWhenAvailable` | Si a medianoche estaba apagado, corre al encender. |
| `-ExecutionTimeLimit 60` | Si un popup queda abierto, la tarea no queda colgada para siempre. |

### Paso 5 - Verificacion de punta a punta

```powershell
Start-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH"
Start-Sleep -Seconds 8

Get-ScheduledTaskInfo -TaskName "Seguridad - Revision Puerto SSH" |
    Select-Object LastRunTime, LastTaskResult, NextRunTime

Get-EventLog -LogName Application -Source "Seguridad-Port22" -Newest 1 |
    Format-List TimeGenerated, EntryType, EventId, Message
```

- `LastTaskResult : 0` = corrio sin error.
- El evento debe tener la hora actual.

### Paso 6 - (Opcional) Endurecimiento

```powershell
Set-NetFirewallProfile -Profile Domain,Public,Private `
    -DefaultInboundAction Block -DefaultOutboundAction Allow
```

Revertir:

```powershell
Set-NetFirewallProfile -Profile Domain,Public,Private `
    -DefaultInboundAction NotConfigured -DefaultOutboundAction NotConfigured
```

Otras medidas opcionales (no son requisito del radar):

```powershell
# SMBv1
Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart

# Cola de impresion (si no se imprimen documentos)
Set-Service -Name Spooler -StartupType Disabled
Stop-Service -Name Spooler -Force

# Auditoria de PowerShell y creacion de procesos
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 1
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockInvocationLogging" -Value 1
auditpol /set /subcategory:"Process Creation" /success:enable
```

---

## 4. Que revisa

| Area | Detecta | Severidad | Usa baseline |
|------|---------|-----------|--------------|
| SSH | Puerto 22 escuchando / servicio `sshd` | Critico / Aviso | No |
| Puertos | Procesos no habituales escuchando en red | Aviso | No (whitelist) |
| Tareas | Tareas programadas nuevas | Aviso | **Si** |
| Defender | RTP apagado, amenazas activas | Critico | No |
| Defender | Modo pasivo, tamper off, firmas viejas | Aviso | No |
| Defender | Exclusiones nuevas | Critico | **Si** |
| Firewall | Perfil apagado o entradas permitidas por defecto | Critico | No |
| Firewall | Reglas de entrada nuevas expuestas (Any/Public) | Critico | **Si** |
| RDP | Escritorio Remoto habilitado | Critico* | No |
| RDP | NLA off / puerto no estandar | Aviso | No |
| WinRM | Servicio corriendo | Critico* | No |
| WinRM | Arranque Automatico (se iniciaria al reiniciar) | Aviso | No |
| Identidad | Nuevos administradores locales | Critico | **Si** |
| Identidad | Cuentas locales nuevas o modificadas | Critico | **Si** |
| Identidad | Guest o Administrator integrado habilitados | Aviso | No |
| Identidad | Autologon con contrasena, UAC off, WDigest = 1 | Critico | No |

\* Se puede aceptar como estado conocido con `Aceptados.RDP` / `Aceptados.WinRM` en la config (pasa a informativo).

### Detalle

**SSH.** Critico si algo escucha en 22. Aviso si el servicio `sshd` existe aunque este detenido (senal de instalacion no deseada).

**Puertos.** Lista lo que escucha en `0.0.0.0` / `::`, resuelve el proceso dueno y descarta los de `ProcesosPermitidos`. Para sumar uno legitimo, editalo en `Radar.config.psd1`.

**Tareas.** Baseline con ruta y nombre de cada tarea. Alerta solo por las que no existian. Si aparece una legitima (actualizacion de un programa), se acepta con `-AprobarTareas` o `-AprobarBaselines`.

**Defender.**
- `RealTimeProtectionEnabled = False` (y sin antivirus de terceros en modo pasivo) -> **Critico**.
- `AMRunningMode` pasivo -> Aviso (hay otro AV).
- `IsTamperProtected = False` -> Aviso.
- `AntivirusSignatureAge` > `DiasFirmaDefender` (default 4) -> Aviso.
- `Get-MpThreat` con amenazas activas -> **Critico**.
- Exclusiones nuevas respecto a la baseline -> **Critico** (tecnica clasica para que el AV ignore una carpeta).

**Firewall.**
- Cualquier perfil con `Enabled = False` -> **Critico**.
- Cualquier perfil con `DefaultInboundAction = Allow` -> **Critico**.
- Reglas de entrada `Allow` + `Enabled` + remoto `Any` + perfil `Public`/`Any` nuevas -> **Critico** (expuestas a la red).

**RDP / WinRM.**
- `fDenyTSConnections = 0` -> RDP habilitado (**Critico**).
- `UserAuthentication = 0` -> RDP sin NLA (Aviso).
- `WinRM` corriendo o escuchando en 5985/5986 -> **Critico**.
- `WinRM` con arranque Automatico pero detenido -> Aviso. (El default de Windows, Manual y detenido, **no** alerta.)
- El chequeo **no usa** el proveedor `WSMan:\`: al accederlo, PowerShell ofrece iniciar el servicio WinRM y en la tarea oculta quedaria esperando respuesta.

**Identidad.**
- Nuevo miembro en Administradores locales (comparado por SID, funciona en Windows en espanol) -> **Critico**.
- Cuenta local nueva o con estado cambiado (habilitada/deshabilitada) -> **Critico**.
- Guest habilitado -> Aviso. Administrator integrado habilitado -> Aviso.
- `Winlogon\DefaultPassword` presente -> **Critico** (contrasena en texto plano).
- `EnableLUA != 1` -> **Critico** (UAC apagado).
- `WDigest\UseLogonCredential = 1` -> **Critico** (credenciales recuperables de memoria).

### Severidades, eventos y popup

| Resultado | Evento | ID | Popup |
|-----------|--------|----|-------|
| Sin hallazgos | Information | 1000 | No |
| Solo avisos | Warning | 1002 | No (por defecto) |
| Al menos un critico | Error | 1001 | **Si** |

El popup muestra **el detalle completo** de criticos y avisos (con scroll), tiene un boton **Copiar** y, abajo, el **path del informe como link**: un click abre el `.log` de esa corrida en Notepad, sin pasar por el Visor de Eventos.

Si queres popup tambien para avisos, cambia en `Radar.config.psd1`:

```powershell
PopupSoloCritico = $false
```

### Informe de cada corrida (`logs\`)

Cada corrida deja un archivo `logs\radar-AAAAMMDD-HHMMSS.log` con:

- fecha, equipo, usuario y si corrio elevado;
- el evento escrito (log, source, ID, tipo);
- los hallazgos agrupados por severidad (**criticos**, **avisos**, **informativos**);
- el mensaje exacto que quedo en el Event Log;
- los comandos para aprobar las novedades.

El mismo path se agrega al final del evento en el Visor, asi que tambien se puede llegar al archivo desde ahi.

Se conservan los ultimos `RetencionInformes` (60 por defecto) y el resto se borra solo. `logs\` esta en `.gitignore`.

Para abrir el ultimo informe sin correr nada:

```powershell
.\Check-Port22.ps1 -AbrirUltimo
```

O desde el Explorador: `C:\Scripts\logs\` (ordenado por fecha).

### Configuracion (`Radar.config.psd1`)

| Clave | Default | Significado |
|-------|---------|-------------|
| `PopupSoloCritico` | `$true` | Solo criticos abren popup. |
| `RetencionInformes` | `60` | Cuantos `.log` se conservan en `logs\` (`0` = sin limite). |
| `AbrirDetalleCon` | `'notepad.exe'` | Programa que abre el informe al clickear el path. `''` = asociacion de Windows (ojo: `.log` no siempre tiene), `'code.cmd'` = VS Code. |
| `Umbrales.DiasFirmaDefender` | `4` | Dias maximos de antiguedad de firmas. |
| `Aceptados.RDP` | `$false` | `$true` si usas Escritorio Remoto a proposito. |
| `Aceptados.WinRM` | `$false` | `$true` si usas WinRM a proposito. |
| `ProcesosPermitidos` | lista | Procesos que pueden escuchar en red sin aviso. |
| `Ignorar.ReglasFirewall` | `@()` | Patrones con comodines (`*`, `?`) sobre `Name` o `DisplayName` de reglas a no vigilar (ej: `Microsoft Edge*`). |
| `Ignorar.TareasPath` | `@('\SoftLanding\*')` | Patrones con comodines sobre el `TaskPath` de tareas a no vigilar. |

Si el archivo falta o es invalido, el script usa los valores por defecto (avisa por consola).

#### Normalizacion de identificadores (anti falso positivo)

Windows Update y algunos instaladores (Edge, Brave, Firefox, WebView2) **borran y recrean** sus tareas y reglas de firewall con **GUIDs nuevos** y IDs numericos largos en cada actualizacion. Si la baseline guardara el nombre crudo, cada update pareceria una novedad y dispararia un critico diario.

Por eso el script normaliza la clave antes de comparar (`ConvertTo-ClaveEstable`):

- `{A799B4F5-3FC8-45FC-B49C-C8E8FEB9D490}` -> `{GUID}`
- `C08CB7B8-9B3C-408E-8E30-5E16A3AEB445` -> `{GUID}` (GUID **sin llaves**, formato de HNS)
- `HNS ... - <GUID> - 0` -> `HNS ... - {GUID} - <ID>` (contador de HNS)
- `render-128000000001615609-...` -> `render-<ID>`

Resultado: doce reglas `Microsoft Edge (mDNS-In)` con GUID distinto colapsan en **una sola clave estable**; lo mismo para las tareas de `\SoftLanding\` y para las reglas `HNS Container Networking` que el servicio de red de Hyper-V/WSL recrea con GUID y contador nuevos. Una regla o tarea **realmente nueva** (otro nombre, otra ruta, otro perfil) sigue alertando.

No confundir con `Ignorar.*`, que es para **silenciar areas completas** por decision tuya. La normalizacion no oculta nada: solo evita que un GUID nuevo cuente como cambio.

### Reglas `HNS Container Networking` (Hyper-V / WSL)

Si usas maquinas virtuales de Hyper-V o contenedores, el servicio `hns` crea reglas de entrada que **permiten DNS (puerto 53, UDP y TCP) desde cualquier origen y en cualquier perfil**, apuntando al proxy DNS de ICS (`SharedAccess`) que escucha en `0.0.0.0:53`.

- **No son malware**: son plumbing del *Default Switch* de Hyper-V. Se recrean solas; no conviene borrarlas.
- **Si te molesta que el puerto 53 quede expuesto en la red local**, agrega una regla de bloqueo de mayor precedencia (las de bloqueo ganan a las de permiso):

```powershell
# Bloquear DNS entrante SOLO en las interfaces fisicas (el Default Switch no se toca)
foreach ($proto in 'UDP', 'TCP') {
    New-NetFirewallRule -DisplayName "Bloquear DNS entrante en LAN ($proto)" `
        -Direction Inbound -Action Block -Protocol $proto -LocalPort 53 `
        -Profile Any -InterfaceType Wired, Wireless
}
```

- Si igual aparecen alertas por estas reglas, silencialas: `Ignorar.ReglasFirewall = @('HNS Container Networking*')`.

### Reglas `Query User{...}` (prompts de firewall)

Cuando Windows muestra el cartel *"Windows Security Alert"* (una aplicacion quiere abrir puertos) y se elige **Allow access**, se crean dos reglas llamadas `TCP Query User{...}<ruta.exe>` y `UDP Query User{...}<ruta.exe>`: permiten **cualquier puerto** entrante a ese ejecutable en el perfil donde se acepto (normalmente Public).

Son un permiso amplio y permanente para ese programa. El radar las marca como criticas si son nuevas. Para verlas y borrarlas:

```powershell
Get-NetFirewallRule | Where-Object { $_.Name -like '*Query User*' } |
    Select-Object DisplayName, Direction, Action, Profile

# Borrar las de un programa puntual
Get-NetFirewallRule | Where-Object { $_.Name -like '*Query User*powershell.exe' } | Remove-NetFirewallRule
```

> Si preferis que Windows no vuelva a preguntar por cada programa, no marques "Allow access" a ciegas: primero mira que ejecutable y que perfil (Public) esta pidiendo.

### Lineas base

Se guardan en `baseline\` junto al script:

| Archivo | Contenido |
|---------|-----------|
| `tareas.json` | Ruta + nombre de cada tarea programada |
| `defender-exclusiones.json` | Exclusiones de Defender por tipo |
| `firewall-reglas.json` | Reglas de entrada permitidas expuestas |
| `identidad-admins.json` | Miembros de Administradores (SID) |
| `identidad-usuarios.json` | Cuentas locales y su estado |

Reglas de actualizacion:

- Solo se crean/actualizan en corridas **elevadas** (la tarea o el instalador). Sin Administrador ni se leen ni se escriben.
- Si el archivo **no existe**: se crea en silencio (primera corrida elevada).
- Si **no hay novedades**: se refresca sola (asi los borrados no generan ruido).
- Si **hay novedades**: alerta y **no** se actualiza. Te va a avisar todos los dias hasta que actues o aceptes.
- Con `-AprobarBaselines`: acepta todo y no alerta en esa corrida.

---

## 5. Que hacer cuando salta una alerta

### SSH abierto

```powershell
Get-NetTCPConnection -LocalPort 22 -State Listen | Select-Object LocalAddress, OwningProcess
Get-Process -Id (Get-NetTCPConnection -LocalPort 22 -State Listen).OwningProcess | Select-Object Name, Path

Stop-Service -Name sshd -Force
Set-Service  -Name sshd -StartupType Disabled

# Si no lo necesitas
Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object Name, State
Remove-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0"
```

### Defender en rojo

```powershell
Get-MpComputerStatus | Select RealTimeProtectionEnabled, AntivirusSignatureAge, AMRunningMode, IsTamperProtected
Set-MpPreference -DisableRealtimeMonitoring $false
Update-MpSignature
Start-MpScan -ScanType QuickScan
Get-MpThreat | Where-Object IsActive | Select ThreatName, SeverityID, Resources
```

Si `IsTamperProtected` esta en False, activalo en Seguridad de Windows -> Proteccion antivirus -> Administrar la configuracion.
Si aparecen **exclusiones nuevas** que no agregaste vos, revisa la ruta excluida antes de borrarla:

```powershell
(Get-MpPreference).ExclusionPath
Remove-MpPreference -ExclusionPath "<ruta>"
```

### Firewall en rojo

```powershell
Get-NetFirewallProfile | Select Name, Enabled, DefaultInboundAction
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True -DefaultInboundAction Block
```

Regla nueva expuesta:

```powershell
Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow |
    Where-Object { ($_.RemoteAddress -join ',') -eq '' -and "$($_.Profile)" -match 'Public|Any' } |
    Select-Object DisplayName, Name, Profile
```

Si no la reconoces: `Disable-NetFirewallRule -Name "<Name>"`.
Si es legitima: `& "C:\Scripts\Check-Port22.ps1" -AprobarBaselines`.

> Antes de aprobar, mira el **nombre**: `HNS Container Networking ...` es de Hyper-V/WSL (normal, ver seccion 4) y `Query User{...}<exe>` es un permiso que se acepto en el cartel de Windows Firewall (amplio y permanente: revisalo).

### RDP / WinRM habilitados sin querer

```powershell
# Deshabilitar RDP
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1

# Deshabilitar WinRM
Stop-Service WinRM -Force
Set-Service WinRM -StartupType Disabled
```

Si los usas a proposito, evita el criticos eternos:

```powershell
# En Radar.config.psd1
Aceptados = @{ RDP = $true; WinRM = $false }
```

### Identidad

```powershell
# Quien esta en Administradores
Get-LocalGroup -SID 'S-1-5-32-544' | Get-LocalGroupMember | Select Name, ObjectClass, PrincipalSource

# Cuentas y estado
Get-LocalUser | Select Name, Enabled, PasswordRequired, PasswordLastSet, LastLogon

# Autologon en texto plano
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' | Select DefaultUserName, DefaultPassword
```

Quitar un administrador: `Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member '<nombre>'`.
Deshabilitar cuenta: `Disable-LocalUser -Name '<nombre>'`.
Quitar contrasena de autologon: borrar el valor `DefaultPassword` y, si no lo usas, `AutoAdminLogon = 0`.

### Tareas programadas nuevas

```powershell
$t = Get-ScheduledTask -TaskPath "\" -TaskName "<NOMBRE>"
$t.Actions | Format-List Execute, Arguments
$t.Principal | Format-List UserId, RunLevel
Export-ScheduledTask -TaskName "<NOMBRE>" -TaskPath "\"
```

Si la reconoces: `-AprobarTareas`. Si no: `Unregister-ScheduledTask -TaskName "<NOMBRE>" -TaskPath "\" -Confirm:$false`.

---

## 6. Comandos de uso diario

```powershell
# Correr el radar (con popup)
& "C:\Scripts\Check-Port22.ps1"

# Correr sin popup (pruebas / consola)
& "C:\Scripts\Check-Port22.ps1" -SinPopup

# Aceptar todas las novedades como conocidas
& "C:\Scripts\Check-Port22.ps1" -AprobarBaselines

# Aceptar solo tareas nuevas
& "C:\Scripts\Check-Port22.ps1" -AprobarTareas

# Abrir el informe de la ultima corrida (sin correr chequeos)
& "C:\Scripts\Check-Port22.ps1" -AbrirUltimo

# Ver el ultimo informe sin abrirlo
Get-ChildItem "C:\Scripts\logs\radar-*.log" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    Get-Content

# Ver hallazgos recientes (Event Log)
Get-EventLog -LogName Application -Source "Seguridad-Port22" -Newest 10 |
    Format-Table TimeGenerated, EntryType, EventId, Message -AutoSize -Wrap

# Solo alertas (criticos)
Get-EventLog -LogName Application -Source "Seguridad-Port22" -EntryType Error |
    Format-List TimeGenerated, Message

# Forzar la tarea
Start-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH"
```

### Probar que la alerta funciona

En PowerShell **como Administrador** (los chequeos con baseline se omiten sin elevacion):

```powershell
# 1. Rompe una baseline a proposito (simula una novedad)
$f = "C:\Scripts\baseline\firewall-reglas.json"
$o = Get-Content $f -Raw | ConvertFrom-Json
$o.items = @($o.items)[1..(@($o.items).Count-1)]
@{ items = @($o.items) } | ConvertTo-Json -Depth 5 | Set-Content $f -Encoding UTF8

# 2. Deberia reportar 1 critico y mostrar popup
& "C:\Scripts\Check-Port22.ps1"

# 3. Restaurar (acepta la baseline actual y no vuelve a alertar)
& "C:\Scripts\Check-Port22.ps1" -AprobarBaselines
```

---

## 7. Troubleshooting

| Sintoma | Causa | Solucion |
|---------|-------|----------|
| `Unexpected token ...` o caracteres raros | Archivo en ANSI/Windows-1252 | Guardar como UTF-8 con BOM (paso 1). |
| `The source name "Seguridad-Port22" does not exist` | Falta el paso 2 | Registrar la fuente como Administrador. |
| `Defender: Exclusiones no legibles sin permisos de Administrador` | Corrida no elevada (no deberia pasar: los chequeos de baseline se omiten) | Normal. La tarea (Highest) los ejecuta. Correr el script elevado para verificarlos a mano. |
| `Sin Administrador: se omiten los chequeos con linea base` | Corrida sin elevar | Esperado. Para el chequeo completo: `Start-ScheduledTask` o PowerShell elevado. |
| `No se pudo crear ...\baseline` | Carpeta sin permisos de escritura | Mover el proyecto a una carpeta del usuario o dar permisos. |
| `Radar.config.psd1 invalido` | Error de sintaxis en la config | Validar con `Import-PowerShellDataFile .\Radar.config.psd1`. |
| Avisos diarios pero **ningun popup** | Por diseno (`PopupSoloCritico = $true`) | Abrir el informe de `logs\` (`-AbrirUltimo`), revisar el ID 1002 en el Visor o poner `PopupSoloCritico = $false`. |
| Critico eterno de RDP/WinRM | Los usas a proposito | `Aceptados.RDP = $true` / `Aceptados.WinRM = $true`. |
| Critico de una regla de firewall legitima | Windows/software agrego una regla | `-AprobarBaselines` o `Ignorar.ReglasFirewall` (acepta comodines). |
| Critico diario por `Microsoft Edge (mDNS-In)` / `Brave (mDNS-In)` / `Firefox` despues de actualizar el navegador | Version vieja del script: la baseline guardaba el GUID del `Name`, que el navegador regenera en cada update | Actualizar `Check-Port22.ps1` (normaliza GUIDs) y borrar `baseline\firewall-reglas.json` para que se regenere. |
| Aviso diario por tareas `\SoftLanding\S-1-5-...` | Componente SoftLanding de Windows Update: recrea sus tareas con GUID/ID nuevos | Ya excluido por `Ignorar.TareasPath = @('\SoftLanding\*')`. Si usas una version vieja, actualizala. |
| `Register-ScheduledTask : ... ya existe` | Tarea duplicada | Reejecutar `Install-Radar.ps1` (usa `-Force`). |
| La tarea corre pero no hay popup | Sesion bloqueada o cerrada | El popup aparece en sesion interactiva; el informe queda igual en `logs\`. |
| El link del popup no abre nada | El programa configurado en `AbrirDetalleCon` no existe | Corregir `AbrirDetalleCon` (`'notepad.exe'` siempre funciona) o poner `''` para usar la asociacion de Windows. El path tambien se puede copiar con el boton **Copiar**. |
| Quiero ver que paso sin abrir el Visor de Eventos | - | `.\Check-Port22.ps1 -AbrirUltimo` abre el informe de la ultima corrida. |
| La tarea queda `Running` para siempre y `LastTaskResult = 267009` | Algun comando abrio un prompt (tipico: proveedor `WSMan:\` ofreciendo iniciar WinRM) en la ventana oculta | Corregido: el script ya no usa `WSMan:\` y la tarea corre con `-NonInteractive`. Detener la tarea colgada (ver abajo) y reinstalar. |
| Pregunta `Start WinRM Service ... Do you want to continue?` al correr el radar | Version vieja del chequeo de WinRM accedia a `WSMan:\localhost\Listener` | Actualizar `Check-Port22.ps1` y reinstalar. Responder `N` no cambia nada. |
| `Install-Radar.ps1` parece no hacer nada | Se relanzo elevado en otra ventana | Aceptar el UAC y mirar la ventana nueva. |
| Baseline borrada por error | - | Se recrea sola y en silencio en la proxima corrida. |

### Detener una tarea colgada (Administrador)

```powershell
Stop-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH"
Get-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH" | Select-Object State
```

Si sigue en `Running`, matar solo el proceso del radar:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*Check-Port22.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

---

## 8. Mantenimiento

### Cambiar la hora

```powershell
$t1 = New-ScheduledTaskTrigger -Daily -At "11:00PM"
$t2 = New-ScheduledTaskTrigger -AtLogOn
Set-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH" -Trigger $t1, $t2
```

### Pausar

```powershell
Disable-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH"
Enable-ScheduledTask  -TaskName "Seguridad - Revision Puerto SSH"
```

### Reiniciar todas las lineas base

Solo cuando el estado actual es confiable:

```powershell
Remove-Item "C:\Scripts\baseline\*.json"
& "C:\Scripts\Check-Port22.ps1" -SinPopup
```

### Desinstalacion

```powershell
.\Install-Radar.ps1 -Uninstall     # tarea + fuente de Event Log + baselines
```

Manual:

```powershell
Unregister-ScheduledTask -TaskName "Seguridad - Revision Puerto SSH" -Confirm:$false
Remove-EventLog -Source "Seguridad-Port22"
Remove-Item "C:\Scripts\baseline" -Recurse -Force
```

---

## 9. Calidad y proteccion de la rama

### CI (GitHub Actions)

`.github/workflows/ci.yml` corre en cada push o PR a `main`:

1. **PSScriptAnalyzer** con `Severity Error` (falla el build si hay errores).
2. **Reporte** de advertencias (no falla, queda visible).
3. **Pester** sobre `tests\` (11 tests de las lineas base).

El job se llama exactamente **`PSScriptAnalyzer`**, que es el `context` que exige el ruleset estricto.

Para correr lo mismo local:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -RequiredVersion 5.7.1

Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester .\tests
```

### Rulesets

| Archivo | Estado | Que hace |
|---------|--------|----------|
| `.github/rulesets/main-protection.json` | `active` | Bloquea borrar `main`, force-push y merge commits |
| `.github/rulesets/main-protection-strict.json` | `evaluate` | Exige PR, check `PSScriptAnalyzer` y rama al dia |

Importar: **Settings -> Rules -> Rulesets -> New ruleset -> Import a ruleset**.

Por API:

```powershell
gh api --method POST repos/pedrogfleming/w11-security-tools/rulesets `
  --input .github/rulesets/main-protection.json
```

> Un ruleset protege el **historial**, no detecta vulnerabilidades. Para eso: **secret scanning + push protection** (Settings -> Code security), el CI de arriba y revision de cambios. `required_approving_review_count` esta en 0 porque GitHub no permite aprobar el propio PR; con un solo mantenedor, exigir 1 aprobacion te deja fuera.

### Secret scanning y push protection

En un repo publico es gratis y es la proteccion mas rentable para este proyecto:

1. Settings -> **Code security**.
2. Activar **Secret scanning** y **Push protection**.
3. Revisar que `.gitignore` cubra `baseline/` (ya cubierto).

---

## 10. Alcance y limitaciones

- **Detecta, no previene.** No bloquea puertos, no mata procesos, no desinstala nada.
- Es una **foto diaria**: si alguien abre el puerto 22 y lo cierra entre dos corridas, no se ve.
- Los chequeos con linea base y las amenazas activas requieren Administrador (la tarea los corre asi; sin admin se omiten).
- La vista del sistema cambia con el privilegio (por ejemplo, `Get-ScheduledTask` muestra 193 tareas sin admin y 262 con admin). Por eso las lineas base solo se escriben elevadas.
- Un atacante con Administrador puede deshabilitar la tarea, borrar `baseline\` o la fuente del Event Log. Esto es higiene, no un EDR.
- Las lineas base son **por maquina**: no se comparten entre equipos (y no deben subirse a un repo).
- Fase 2 pendiente: persistencia avanzada (Run keys, WMI), DNS/hosts, eventos 4625/1102/4688/4104, parches, BitLocker.

---

## 11. Checklist final

- [ ] `Check-Port22.ps1` existe y empieza con BOM (`239 187 191`).
- [ ] `Radar.config.psd1` presente (o se aceptan los defaults).
- [ ] `Install-Radar.ps1` corrido sin errores.
- [ ] Fuente `Seguridad-Port22` registrada en `Application`.
- [ ] `baseline\` contiene los 5 archivos JSON.
- [ ] Tarea con 2 triggers, `RunLevel = Highest`, `LogonType = Interactive`.
- [ ] `LastTaskResult = 0` y evento con la hora actual.
- [ ] Prueba de popup: romper una baseline, ver el popup y restaurar con `-AprobarBaselines`.
- [ ] `Invoke-Pester .\tests` pasa (11/11) y `Invoke-ScriptAnalyzer` no da errores.
- [ ] Workflow **CI** verde tras el primer push.
- [ ] Ruleset `main-protection` importado y **Active**.
- [ ] Secret scanning + push protection activados en el repo.

---

## Licencia

MIT. Ver [`LICENSE`](LICENSE).

---

## Apendice A - Script (`Check-Port22.ps1`)

> Fuente de verdad: el archivo en disco. Si difieren, gana el archivo.

```powershell
# ==========================================
# SCRIPT: Radar de Seguridad Diario  (fase 1)
# Chequeos: SSH, puertos expuestos, tareas nuevas,
#           Defender, Firewall, RDP/WinRM, Identidad
#
# Uso:
#   .\Check-Port22.ps1                  # corrida normal
#   .\Check-Port22.ps1 -SinPopup        # prueba: no muestra popup
#   .\Check-Port22.ps1 -AbrirUltimo     # abre el ultimo informe de logs\ y sale
#   .\Check-Port22.ps1 -AprobarBaselines # acepta TODAS las novedades como conocidas
#   .\Check-Port22.ps1 -AprobarTareas    # solo tareas programadas
# ==========================================

param(
    [switch]$AprobarTareas,
    [switch]$AprobarBaselines,
    [switch]$SinPopup,
    [switch]$AbrirUltimo
)

$eventoLog      = "Seguridad-Port22"
$logType        = "Application"
$script:baseDir = Join-Path $PSScriptRoot "baseline"
$script:logsDir = Join-Path $PSScriptRoot "logs"
$refTareasTxt   = Join-Path $PSScriptRoot "tareas_baseline.txt"

$script:AprobarTodo   = [bool]$AprobarBaselines
$script:AprobarTareas = ([bool]$AprobarTareas -or [bool]$AprobarBaselines)

# ---------------------------------------------------------
# Configuracion (Radar.config.psd1) con defaults
# ---------------------------------------------------------
$config = @{
    PopupSoloCritico = $true
    # Cuantos informes .log se conservan en logs\ (0 = sin limite)
    RetencionInformes = 60
    # Programa con el que se abre el informe desde el popup.
    # 'notepad.exe' = Notepad (siempre disponible, recomendado)
    # ''            = aplicacion asociada de Windows (puede no existir para .log)
    # 'code.cmd'    = VS Code, si esta en el PATH
    AbrirDetalleCon = 'notepad.exe'
    Umbrales = @{
        DiasFirmaDefender = 4
    }
    Aceptados = @{
        RDP   = $false
        WinRM = $false
    }
    ProcesosPermitidos = @(
        'svchost','lsass','System','smss','csrss','services','wininit','winlogon',
        'dwm','RuntimeBroker','SearchIndexer','MsMpEng','NisSrv','vmms'
    )
    Ignorar = @{
        # Patrones con comodines sobre Name o DisplayName de la regla
        ReglasFirewall = @()
        # Patrones con comodines sobre el TaskPath
        TareasPath     = @('\SoftLanding\*')
    }
}

$configPath = Join-Path $PSScriptRoot "Radar.config.psd1"
if (Test-Path $configPath) {
    try {
        $cfg = Import-PowerShellDataFile -Path $configPath
        foreach ($k in $cfg.Keys) {
            if ($k -in @('Umbrales','Aceptados','Ignorar')) {
                foreach ($kk in $cfg[$k].Keys) { $config[$k][$kk] = $cfg[$k][$kk] }
            } else {
                $config[$k] = $cfg[$k]
            }
        }
    } catch {
        Write-Warning "Radar.config.psd1 invalido, se usan los valores por defecto: $($_.Exception.Message)"
    }
}
$script:Config = $config

# Elevacion: los chequeos con linea base solo corren elevados, porque la vista
# del sistema cambia segun el privilegio (ej: Get-ScheduledTask ve 193 tareas
# sin admin y 262 con admin). La tarea programada corre con RunLevel Highest.
$script:EsAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------
# Helpers
# ---------------------------------------------------------
function New-Hallazgo {
    param(
        [ValidateSet('Critico','Aviso','Info')][string]$Severidad,
        [string]$Area,
        [string]$Detalle
    )
    [pscustomobject]@{ Severidad = $Severidad; Area = $Area; Detalle = $Detalle }
}

# Normaliza identificadores volatiles: GUIDs y numeros largos que los
# instaladores (Edge, Windows Update) regeneran en cada actualizacion.
# Sin esto, cada update parece "regla/tarea nueva" y genera falsos criticos.
function ConvertTo-ClaveEstable {
    param([string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return '' }

    # GUID con o sin llaves: HNS (Hyper-V / WSL) los usa sin llaves.
    $t = $Texto -replace '\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?', '{GUID}'
    # Contador que HNS agrega detras del GUID: "HNS ... - {GUID} - 0".
    $t = $t -replace '(\{GUID\}\s*-\s*)\d+$', '${1}<ID>'
    $t = $t -replace '\d{12,}', '<ID>'
    return $t
}

# Compara valores contra patrones con comodines (* y ?).
function Test-Ignorado {
    param([string[]]$Valores, [string[]]$Patrones)

    foreach ($p in @($Patrones)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        foreach ($v in @($Valores)) {
            if ([string]::IsNullOrWhiteSpace($v)) { continue }
            if ($v -like $p) { return $true }
        }
    }
    return $false
}

function Initialize-BaseDir {
    if (-not (Test-Path $script:baseDir)) {
        try { New-Item -ItemType Directory -Path $script:baseDir -Force | Out-Null }
        catch { Write-Warning "No se pudo crear $script:baseDir : $($_.Exception.Message)" }
    }
}

function Read-Baseline {
    param([string]$Nombre)
    $f = Join-Path $script:baseDir "$Nombre.json"

    # Devuelve un objeto siempre (nunca un array suelto): evita que PowerShell
    # "desenrolle" arreglos vacios o de un solo elemento al asignarlos.
    if (-not (Test-Path $f)) {
        return [pscustomobject]@{ Ok = $false; Items = @() }
    }

    try {
        $o = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = @($o.items | Where-Object { $null -ne $_ })
        return [pscustomobject]@{ Ok = $true; Items = $items }
    } catch {
        Write-Warning "Baseline '$Nombre' ilegible; se regenera."
        return [pscustomobject]@{ Ok = $false; Items = @() }
    }
}

function Write-Baseline {
    param([string]$Nombre, [string[]]$Items)
    $f = Join-Path $script:baseDir "$Nombre.json"
    try {
        @{ items = @($Items | Sort-Object -Unique) } | ConvertTo-Json -Depth 5 |
            Set-Content -Path $f -Encoding UTF8
    } catch {
        Write-Warning "No se pudo guardar la baseline '$Nombre': $($_.Exception.Message)"
    }
}

function Compare-ConBaseline {
    param(
        [string]$Nombre,
        [string[]]$Actual,
        [switch]$Aprobar
    )
    $actualOrdenado = @($Actual | Sort-Object -Unique)

    $lectura = Read-Baseline -Nombre $Nombre
    if (-not $lectura.Ok) {
        Write-Baseline -Nombre $Nombre -Items $actualOrdenado
        return [pscustomobject]@{ Nuevos = @(); Primera = $true; Aprobado = $false }
    }

    $previos = @($lectura.Items)
    $nuevos = @(Compare-Object -ReferenceObject $previos -DifferenceObject $actualOrdenado -ErrorAction Stop |
        Where-Object { $_.SideIndicator -eq '=>' } |
        Select-Object -ExpandProperty InputObject)

    $aprobado = $false
    if ($Aprobar) {
        $aprobado = $true
        Write-Baseline -Nombre $Nombre -Items $actualOrdenado
    } elseif ($nuevos.Count -eq 0) {
        Write-Baseline -Nombre $Nombre -Items $actualOrdenado
    }

    return [pscustomobject]@{ Nuevos = $nuevos; Primera = $false; Aprobado = $aprobado }
}

function Write-LogSeguridad {
    param([string]$Mensaje, [string]$Tipo = 'Information', [int]$Id = 1000)
    try {
        Write-EventLog -LogName $logType -Source $eventoLog -EventId $Id `
            -EntryType $Tipo -Message $Mensaje -ErrorAction Stop
    } catch {
        Write-Warning "No se pudo escribir en el Event Log: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------
# Informe de ejecucion en archivo (para no abrir el Visor de Eventos)
# ---------------------------------------------------------
function Write-InformeEjecucion {
    param(
        [string]$Mensaje = '',
        [int]$EventId = 1000,
        [string]$TipoEvento = 'Information',
        [string]$Resumen = '',
        $Hallazgos = @(),
        [string]$Directorio = $script:logsDir
    )

    if ([string]::IsNullOrWhiteSpace($Directorio)) {
        $Directorio = Join-Path $PSScriptRoot 'logs'
    }

    try {
        if (-not (Test-Path $Directorio)) {
            New-Item -ItemType Directory -Path $Directorio -Force | Out-Null
        }

        $ahora = Get-Date
        $marca = $ahora.ToString('yyyyMMdd-HHmmss')
        $ruta = Join-Path $Directorio "radar-$marca.log"
        $n = 1
        while (Test-Path $ruta) {
            $ruta = Join-Path $Directorio "radar-$marca-$n.log"
            $n++
        }

        $sep = '=' * 66
        $lineas = @()
        $lineas += $sep
        $lineas += ' RADAR DE SEGURIDAD - INFORME DE EJECUCION'
        $lineas += $sep
        $lineas += "Fecha     : $($ahora.ToString('dd/MM/yyyy HH:mm:ss'))"
        $lineas += "Equipo    : $env:COMPUTERNAME"
        $lineas += "Usuario   : $env:USERNAME"
        $elevado = 'No'
        if ($script:EsAdmin) { $elevado = 'Si' }
        $lineas += "Elevado   : $elevado"
        $lineas += "Evento    : $logType / $eventoLog / ID $EventId ($TipoEvento)"
        if ($Resumen) { $lineas += "Resultado : $Resumen" }
        $lineas += ''

        $grupos = @(
            @{ Nombre = 'CRITICOS';    Severidad = 'Critico' },
            @{ Nombre = 'AVISOS';      Severidad = 'Aviso' },
            @{ Nombre = 'INFORMATIVOS'; Severidad = 'Info' }
        )
        foreach ($g in $grupos) {
            $items = @($Hallazgos | Where-Object { $_.Severidad -eq $g.Severidad })
            if ($items.Count -eq 0) { continue }
            $lineas += "$($g.Nombre) ($($items.Count))"
            foreach ($h in $items) { $lineas += "  - $($h.Area): $($h.Detalle)" }
            $lineas += ''
        }

        if (-not ($Hallazgos | Where-Object { $_.Severidad -ne 'Info' })) {
            $lineas += 'Sin hallazgos: el equipo mantiene la configuracion esperada.'
            $lineas += ''
        }

        $lineas += $sep
        $lineas += 'Mensaje registrado en el Event Log:'
        $lineas += $sep
        foreach ($l in ($Mensaje -split "`r?`n")) { $lineas += $l }
        $lineas += ''
        $lineas += $sep
        $lineas += 'Para aceptar las novedades como conocidas:'
        $lineas += '  .\Check-Port22.ps1 -AprobarBaselines'
        $lineas += '  .\Check-Port22.ps1 -AprobarTareas     (solo tareas programadas)'
        $lineas += $sep

        [System.IO.File]::WriteAllLines($ruta, [string[]]$lineas, (New-Object System.Text.UTF8Encoding($false)))

        # Retencion: conserva los N informes mas recientes.
        $retencion = 60
        if ($script:Config -and $script:Config.ContainsKey('RetencionInformes')) {
            $retencion = [int]$script:Config.RetencionInformes
        }
        if ($retencion -gt 0) {
            $viejos = @(Get-ChildItem -Path $Directorio -Filter 'radar-*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip $retencion)
            foreach ($v in $viejos) { Remove-Item -Path $v.FullName -Force -ErrorAction SilentlyContinue }
        }

        return $ruta
    } catch {
        Write-Warning "No se pudo escribir el informe de ejecucion: $($_.Exception.Message)"
        return $null
    }
}

# Abre el informe con la aplicacion asociada. Se usa explorer.exe a proposito:
# hereda la sesion del usuario y NO la elevacion, asi el visor no corre como admin.
function Open-InformeRadar {
    param([string]$Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta) -or -not (Test-Path $Ruta)) {
        Write-Warning "El informe no existe: $Ruta"
        return
    }

    $exe = ''
    if ($script:Config -and $script:Config.ContainsKey('AbrirDetalleCon')) {
        $exe = [string]$script:Config.AbrirDetalleCon
    }

    try {
        if ([string]::IsNullOrWhiteSpace($exe)) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Ruta`""
        } else {
            Start-Process -FilePath $exe -ArgumentList "`"$Ruta`""
        }
    } catch {
        try {
            Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$Ruta`""
        } catch {
            Write-Warning "No se pudo abrir el informe: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------
# Popup con el detalle y un link al informe completo
# ---------------------------------------------------------
function Show-PopupRadar {
    param(
        [string]$Titulo = 'RADAR DE SEGURIDAD',
        [string]$Texto = '',
        [string]$RutaInforme = ''
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        Write-Warning "No se pudo cargar WinForms: $($_.Exception.Message)"
        return
    }

    $hayInforme = (-not [string]::IsNullOrWhiteSpace($RutaInforme)) -and (Test-Path $RutaInforme)

    # Coordenadas precalculadas: dentro de un New-Object(...) no se puede
    # usar aritmetica sin parentesis (PowerShell la parsea como argumento suelto).
    $anchoForm = 700
    $altoForm = 490
    $xLink = 86
    $anchoLink = 372
    $yLink = 434
    $yBotones = 429
    $xBotones = 470

    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Titulo
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.ShowInTaskbar = $true
        $form.TopMost = $true
        $form.ClientSize = New-Object System.Drawing.Size($anchoForm, $altoForm)
        $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        $lblTitulo = New-Object System.Windows.Forms.Label
        $lblTitulo.Text = $Titulo
        $lblTitulo.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        $lblTitulo.ForeColor = [System.Drawing.Color]::FromArgb(160, 20, 20)
        $lblTitulo.AutoSize = $true
        $lblTitulo.Location = New-Object System.Drawing.Point(16, 12)
        $form.Controls.Add($lblTitulo)

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Multiline = $true
        $txt.ReadOnly = $true
        $txt.ScrollBars = 'Both'
        $txt.WordWrap = $false
        $txt.BackColor = [System.Drawing.Color]::White
        $txt.Font = New-Object System.Drawing.Font('Consolas', 9)
        $txt.Location = New-Object System.Drawing.Point(16, 42)
        $txt.Size = New-Object System.Drawing.Size(668, 380)
        $txt.Text = ($Texto -replace "`r?`n", "`r`n")
        $form.Controls.Add($txt)

        if ($hayInforme) {
            $script:RutaInformePopup = $RutaInforme

            # Etiqueta corta a la izquierda y el PATH como link clickeable.
            $lblInforme = New-Object System.Windows.Forms.Label
            $lblInforme.Text = 'Informe:'
            $lblInforme.AutoSize = $true
            $lblInforme.ForeColor = [System.Drawing.Color]::DimGray
            $lblInforme.Location = New-Object System.Drawing.Point(16, $yLink)
            $form.Controls.Add($lblInforme)

            $lnk = New-Object System.Windows.Forms.LinkLabel
            $lnk.Text = $RutaInforme
            $lnk.Location = New-Object System.Drawing.Point($xLink, $yLink)
            $lnk.Size = New-Object System.Drawing.Size($anchoLink, 18)
            $lnk.AutoEllipsis = $true
            $lnk.LinkColor = [System.Drawing.Color]::FromArgb(0, 90, 200)
            $lnk.ActiveLinkColor = [System.Drawing.Color]::FromArgb(200, 60, 0)
            $lnk.Add_LinkClicked({ Open-InformeRadar -Ruta $script:RutaInformePopup })

            $tip = New-Object System.Windows.Forms.ToolTip
            $tip.SetToolTip($lnk, "Click para abrir:`n$RutaInforme")
            $form.Controls.Add($lnk)
        } else {
            $lblSin = New-Object System.Windows.Forms.Label
            $lblSin.Text = 'Sin informe en archivo para esta corrida.'
            $lblSin.AutoSize = $true
            $lblSin.ForeColor = [System.Drawing.Color]::DimGray
            $lblSin.Location = New-Object System.Drawing.Point(16, $yLink)
            $form.Controls.Add($lblSin)
        }

        $btnCopiar = New-Object System.Windows.Forms.Button
        $btnCopiar.Text = 'Copiar'
        $btnCopiar.Size = New-Object System.Drawing.Size(90, 30)
        $btnCopiar.Location = New-Object System.Drawing.Point($xBotones, $yBotones)
        $btnCopiar.Add_Click({
            try {
                [System.Windows.Forms.Clipboard]::SetText($txt.Text)
            } catch {
                Write-Warning "No se pudo copiar al portapapeles: $($_.Exception.Message)"
            }
        })
        $form.Controls.Add($btnCopiar)

        $xCopiar = $xBotones
        $xCerrar = $xCopiar + 100
        $btnCerrar = New-Object System.Windows.Forms.Button
        $btnCerrar.Text = 'Cerrar'
        $btnCerrar.Size = New-Object System.Drawing.Size(90, 30)
        $btnCerrar.Location = New-Object System.Drawing.Point($xCerrar, $yBotones)
        $btnCerrar.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.AcceptButton = $btnCerrar
        $form.CancelButton = $btnCerrar
        $form.Controls.Add($btnCerrar)

        $form.Add_Shown({ $form.Activate() })
        [void]$form.ShowDialog()
        $form.Dispose()
    } catch {
        # Si WinForms falla, siempre queda el aviso clasico.
        Write-Warning "No se pudo mostrar la ventana con link: $($_.Exception.Message)"
        try {
            [System.Windows.Forms.MessageBox]::Show(
                $Texto + "`n`nInforme: $RutaInforme",
                $Titulo,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } catch {
            Write-Output "$Titulo`n$Texto"
        }
    }
}

# ---------------------------------------------------------
# Chequeos
# ---------------------------------------------------------
function Test-PuertoSSH {
    $out = @()

    $ssh = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    if ($ssh) {
        $pids = (@($ssh) | Select-Object -ExpandProperty OwningProcess -Unique) -join ', '
        $out += New-Hallazgo 'Critico' 'SSH' "Puerto 22 ABIERTO y escuchando (PID: $pids)"
    }

    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($svc) {
        $out += New-Hallazgo 'Aviso' 'SSH' "Servicio sshd instalado (estado: $($svc.Status)). Puede abrir el puerto 22."
    }

    return $out
}

function Test-PuertosExpuestos {
    $out = @()

    $lista = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @('0.0.0.0','::') } |
        ForEach-Object {
            $proc   = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            $nombre = if ($proc) { $proc.Name } else { 'desconocido' }
            [pscustomobject]@{ Puerto = $_.LocalPort; Proceso = $nombre }
        } |
        Where-Object { $script:Config.ProcesosPermitidos -notcontains $_.Proceso } |
        Sort-Object Puerto -Unique

    if ($lista) {
        $detalle = (@($lista) | ForEach-Object { "$($_.Puerto) ($($_.Proceso))" }) -join ', '
        $out += New-Hallazgo 'Aviso' 'Puertos' "Escuchando en la red por procesos no habituales: $detalle"
    }

    return $out
}

function Test-TareasProgramadas {
    $out = @()

    if (-not $script:EsAdmin) { return $out }

    $ignorarPath = @($script:Config.Ignorar.TareasPath)

    # La clave se normaliza (GUIDs/IDs -> marcadores) porque Windows Update y
    # algunos instaladores recrean la misma tarea con identificadores nuevos.
    $actuales = @(Get-ScheduledTask |
        Where-Object { -not (Test-Ignorado -Valores @("$($_.TaskPath)") -Patrones $ignorarPath) } |
        ForEach-Object { ConvertTo-ClaveEstable -Texto "$($_.TaskPath)$($_.TaskName)" } |
        Sort-Object -Unique)

    # Migracion: si existe la baseline vieja en texto, se importa una vez
    $jsonTareas = Join-Path $script:baseDir 'tareas.json'
    if (-not (Test-Path $jsonTareas) -and (Test-Path $refTareasTxt)) {
        $previas = @(Get-Content $refTareasTxt |
            Where-Object { $_.Trim() } |
            ForEach-Object { ConvertTo-ClaveEstable -Texto $_.Trim() } |
            Sort-Object -Unique)
        if ($previas.Count -gt 0) {
            Write-Baseline -Nombre 'tareas' -Items $previas
            $out += New-Hallazgo 'Info' 'Tareas' "Linea base migrada desde tareas_baseline.txt ($($previas.Count) tareas)."
        }
    }

    $cmp = Compare-ConBaseline -Nombre 'tareas' -Actual $actuales -Aprobar:$script:AprobarTareas

    if ($cmp.Primera) {
        $out += New-Hallazgo 'Info' 'Tareas' "Linea base creada ($($actuales.Count) tareas)."
    } elseif ($cmp.Aprobado) {
        if ($cmp.Nuevos.Count -gt 0) {
            $out += New-Hallazgo 'Info' 'Tareas' "$($cmp.Nuevos.Count) tareas nuevas aceptadas en la linea base."
        }
    } elseif ($cmp.Nuevos.Count -gt 0) {
        $nombres = (@($cmp.Nuevos) | Sort-Object) -join '; '
        $out += New-Hallazgo 'Aviso' 'Tareas' "Tareas programadas nuevas: $nombres"
    }

    return $out
}

function Test-Defender {
    $out = @()

    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $mp) {
        $out += New-Hallazgo 'Aviso' 'Defender' 'No se pudo leer el estado de Microsoft Defender (posible antivirus de terceros o VM sin Defender).'
        return $out
    }

    $modo = "$($mp.AMRunningMode)"
    if (-not $mp.RealTimeProtectionEnabled) {
        if ($modo -match 'Passive') {
            $out += New-Hallazgo 'Aviso' 'Defender' "Defender en modo '$modo': hay otro antivirus activo."
        } else {
            $out += New-Hallazgo 'Critico' 'Defender' "Proteccion en tiempo real DESACTIVADA (modo: '$modo')."
        }
    }

    if (($mp.PSObject.Properties.Name -contains 'IsTamperProtected') -and (-not $mp.IsTamperProtected)) {
        $out += New-Hallazgo 'Aviso' 'Defender' 'Proteccion contra manipulacion (Tamper Protection) desactivada.'
    }

    $edad = [int]$mp.AntivirusSignatureAge
    if ($edad -gt [int]$script:Config.Umbrales.DiasFirmaDefender) {
        $out += New-Hallazgo 'Aviso' 'Defender' "Firmas con $edad dias de antiguedad (umbral: $($script:Config.Umbrales.DiasFirmaDefender))."
    }

    $activas = @()
    if ($script:EsAdmin) {
        $activas = @(Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { $_.IsActive })
    }
    if ($activas.Count -gt 0) {
        $nombres = (@($activas) | ForEach-Object { $_.ThreatName } | Select-Object -Unique) -join '; '
        $out += New-Hallazgo 'Critico' 'Defender' "Amenazas ACTIVAS detectadas: $nombres"
    }

    if ($script:EsAdmin) {
        $pref = Get-MpPreference -ErrorAction SilentlyContinue
        if ($pref) {
            $crudo = @(@($pref.ExclusionPath) + @($pref.ExclusionProcess) + @($pref.ExclusionExtension)) |
                Where-Object { $_ }

            $sinPermiso = @($crudo | Where-Object { "$_" -match 'Must be an administrator to view exclusions' })
            if ($sinPermiso.Count -gt 0) {
                $out += New-Hallazgo 'Info' 'Defender' 'Exclusiones no legibles sin permisos de Administrador; se omiten en esta corrida.'
            } else {
                $excl = @()
                foreach ($p in @($pref.ExclusionPath))      { if ($p) { $excl += "Ruta|$p" } }
                foreach ($p in @($pref.ExclusionProcess))   { if ($p) { $excl += "Proceso|$p" } }
                foreach ($p in @($pref.ExclusionExtension)) { if ($p) { $excl += "Extension|$p" } }

                $cmp = Compare-ConBaseline -Nombre 'defender-exclusiones' -Actual $excl -Aprobar:$script:AprobarTodo

                if ($cmp.Primera) {
                    $out += New-Hallazgo 'Info' 'Defender' "Linea base de exclusiones creada ($($excl.Count) entradas)."
                } elseif ($cmp.Aprobado) {
                    if ($cmp.Nuevos.Count -gt 0) {
                        $out += New-Hallazgo 'Info' 'Defender' "$($cmp.Nuevos.Count) exclusiones nuevas aceptadas en la linea base."
                    }
                } elseif ($cmp.Nuevos.Count -gt 0) {
                    $out += New-Hallazgo 'Critico' 'Defender' ("Exclusiones NUEVAS en Defender: " + ((@($cmp.Nuevos)) -join '; '))
                }
            }
        }
    }

    return $out
}

function Test-Firewall {
    $out = @()

    $perfiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    if ($perfiles.Count -eq 0) {
        $out += New-Hallazgo 'Aviso' 'Firewall' 'No se pudo leer el estado de los perfiles de firewall.'
    }

    foreach ($p in $perfiles) {
        if (-not $p.Enabled) {
            $out += New-Hallazgo 'Critico' 'Firewall' "Perfil '$($p.Name)' DESHABILITADO."
        }
        if ("$($p.DefaultInboundAction)" -eq 'Allow') {
            $out += New-Hallazgo 'Critico' 'Firewall' "Perfil '$($p.Name)': DefaultInboundAction = Allow (entradas permitidas por defecto)."
        }
    }

    if ($script:EsAdmin) {
        $ignorar = @($script:Config.Ignorar.ReglasFirewall)

        $permitidas = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
            Where-Object {
                # En el objeto de Get-NetFirewallRule, "Any" suele venir como cadena vacia
                $ra = ($_.RemoteAddress -join ',')
                $esAny = [string]::IsNullOrWhiteSpace($ra) -or ($ra -match 'Any')
                $esAny -and ("$($_.Profile)" -match 'Public|Any')
            } |
            ForEach-Object {
                $nombre  = "$($_.Name)"
                $mostrar = "$($_.DisplayName)"
                if ([string]::IsNullOrWhiteSpace($mostrar)) { $mostrar = $nombre }
                [pscustomobject]@{
                    Nombre  = $nombre
                    Mostrar = $mostrar
                    # Name estable: los GUIDs (Edge/Brave/Firefox, WebView2) cambian
                    # en cada actualizacion y no deben contar como regla nueva.
                    Texto   = "$(ConvertTo-ClaveEstable -Texto $nombre)|$mostrar|$($_.Profile)"
                }
            } |
            Where-Object { -not (Test-Ignorado -Valores @($_.Nombre, $_.Mostrar) -Patrones $ignorar) } |
            ForEach-Object { $_.Texto })

        $cmp = Compare-ConBaseline -Nombre 'firewall-reglas' -Actual $permitidas -Aprobar:$script:AprobarTodo

        if ($cmp.Primera) {
            $out += New-Hallazgo 'Info' 'Firewall' "Linea base de reglas de entrada creada ($($permitidas.Count) reglas)."
        } elseif ($cmp.Aprobado) {
            if ($cmp.Nuevos.Count -gt 0) {
                $out += New-Hallazgo 'Info' 'Firewall' "$($cmp.Nuevos.Count) reglas nuevas aceptadas en la linea base."
            }
        } elseif ($cmp.Nuevos.Count -gt 0) {
            $detalle = (@($cmp.Nuevos) | ForEach-Object { ($_ -split '\|', 2)[1] }) -join '; '
            $out += New-Hallazgo 'Critico' 'Firewall' "Reglas de entrada NUEVAS expuestas a redes publicas: $detalle"
        }
    }

    return $out
}

function Test-AccesoRemoto {
    $out = @()

    $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    if ($ts -and $ts.fDenyTSConnections -eq 0) {
        $severidad = if ($script:Config.Aceptados.RDP) { 'Info' } else { 'Critico' }
        $out += New-Hallazgo $severidad 'RDP' 'Escritorio Remoto HABILITADO (fDenyTSConnections = 0).'

        $rdp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue
        if ($rdp) {
            if ($rdp.UserAuthentication -eq 0) {
                $out += New-Hallazgo 'Aviso' 'RDP' 'NLA (Network Level Authentication) deshabilitado.'
            }
            if ($rdp.PortNumber -and $rdp.PortNumber -ne 3389) {
                $out += New-Hallazgo 'Aviso' 'RDP' "RDP configurado en puerto no estandar: $($rdp.PortNumber)."
            }
        }
    }

    # OJO: no usar el proveedor WSMan:\ aca. Al accederlo, PowerShell ofrece
    # INICIAR el servicio WinRM y, en la tarea oculta, queda esperando respuesta.
    $svc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if ($svc) {
        $escucha = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -in @(5985, 5986) })

        if ($svc.Status -eq 'Running' -or $escucha.Count -gt 0) {
            $severidad = if ($script:Config.Aceptados.WinRM) { 'Info' } else { 'Critico' }
            $detalle = if ($svc.Status -eq 'Running') {
                'servicio corriendo'
            } else {
                $puertos = (@($escucha) | Select-Object -ExpandProperty LocalPort -Unique) -join ','
                "escuchando en $puertos"
            }
            $out += New-Hallazgo $severidad 'WinRM' "WinRM activo ($detalle): administracion remota expuesta en 5985/5986."
        } elseif ($svc.StartType -eq 'Automatic') {
            $out += New-Hallazgo 'Aviso' 'WinRM' 'WinRM con arranque automatico: se iniciara en el proximo reinicio.'
        }
    }

    return $out
}

function Test-Identidad {
    $out = @()

    # Administradores locales (por SID: funciona en Windows en espanol)
    if ($script:EsAdmin) {
        $admins = @(Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue |
            Get-LocalGroupMember -ErrorAction SilentlyContinue |
            ForEach-Object { "$($_.ObjectClass)|$($_.SID.Value)|$($_.Name)" })

        $cmp = Compare-ConBaseline -Nombre 'identidad-admins' -Actual $admins -Aprobar:$script:AprobarTodo
        if ($cmp.Primera) {
            $out += New-Hallazgo 'Info' 'Identidad' "Linea base de administradores creada ($($admins.Count) miembros)."
        } elseif ($cmp.Aprobado) {
            if ($cmp.Nuevos.Count -gt 0) {
                $out += New-Hallazgo 'Info' 'Identidad' "$($cmp.Nuevos.Count) cambios de administradores aceptados en la linea base."
            }
        } elseif ($cmp.Nuevos.Count -gt 0) {
            $nombres = (@($cmp.Nuevos) | ForEach-Object { ($_ -split '\|')[2] }) -join '; '
            $out += New-Hallazgo 'Critico' 'Identidad' "NUEVOS miembros en Administradores locales: $nombres"
        }
    }

    # Usuarios locales
    if ($script:EsAdmin) {
        $usuarios = @(Get-LocalUser -ErrorAction SilentlyContinue |
            ForEach-Object { "$($_.Name)|Enabled=$($_.Enabled)|PasswordRequired=$($_.PasswordRequired)" })

        $cmp = Compare-ConBaseline -Nombre 'identidad-usuarios' -Actual $usuarios -Aprobar:$script:AprobarTodo
        if ($cmp.Primera) {
            $out += New-Hallazgo 'Info' 'Identidad' "Linea base de usuarios locales creada ($($usuarios.Count) cuentas)."
        } elseif ($cmp.Aprobado) {
            if ($cmp.Nuevos.Count -gt 0) {
                $out += New-Hallazgo 'Info' 'Identidad' "$($cmp.Nuevos.Count) cambios de cuentas aceptados en la linea base."
            }
        } elseif ($cmp.Nuevos.Count -gt 0) {
            $nombres = (@($cmp.Nuevos) | ForEach-Object { ($_ -split '\|')[0] }) -join '; '
            $out += New-Hallazgo 'Critico' 'Identidad' "Cuentas locales NUEVAS o modificadas: $nombres"
        }
    }

    # Cuentas integradas
    $invitado = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -like '*-501' }
    if ($invitado -and $invitado.Enabled) {
        $out += New-Hallazgo 'Aviso' 'Identidad' "Cuenta Guest/Invitado HABILITADA ($($invitado.Name))."
    }

    $adminIntegrado = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -like '*-500' }
    if ($adminIntegrado -and $adminIntegrado.Enabled) {
        $out += New-Hallazgo 'Aviso' 'Identidad' "Cuenta Administrator integrada HABILITADA ($($adminIntegrado.Name))."
    }

    # Autologon con contrasena en texto plano
    $winlogon = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    if ($winlogon -and $winlogon.DefaultPassword) {
        $out += New-Hallazgo 'Critico' 'Identidad' 'Autologon con contrasena en texto plano en el registro (Winlogon\DefaultPassword).'
    }

    # UAC
    $lsaSystem = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    if ($lsaSystem -and $lsaSystem.EnableLUA -ne 1) {
        $out += New-Hallazgo 'Critico' 'Identidad' "UAC DESHABILITADO (EnableLUA = $($lsaSystem.EnableLUA))."
    }

    # WDigest: almacenamiento de credenciales en claro
    $wdigest = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -Name UseLogonCredential -ErrorAction SilentlyContinue
    if ($wdigest -and $wdigest.UseLogonCredential -eq 1) {
        $out += New-Hallazgo 'Critico' 'Identidad' 'WDigest con UseLogonCredential = 1 (credenciales recuperables desde memoria).'
    }

    return $out
}

# ---------------------------------------------------------
# Ejecucion
# ---------------------------------------------------------
# Atajo: abrir el ultimo informe guardado y salir sin correr chequeos.
if ($AbrirUltimo) {
    $ultimo = Get-ChildItem -Path $script:logsDir -Filter 'radar-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $ultimo) {
        Write-Output "No hay informes en $script:logsDir. Corre el radar al menos una vez."
        return
    }
    Write-Output "Ultimo informe: $($ultimo.FullName)"
    Open-InformeRadar -Ruta $ultimo.FullName
    return
}

Initialize-BaseDir

if (-not $script:EsAdmin) {
    Write-Output "[i] Sin Administrador: se omiten los chequeos con linea base (tareas, exclusiones de Defender, reglas de firewall, identidad) y amenazas activas."
    Write-Output "    Para el chequeo completo: Start-ScheduledTask -TaskName 'Seguridad - Revision Puerto SSH' o PowerShell elevado."
}

$hallazgos = @()

$chequeos = @(
    @{ Nombre = 'SSH';       Funcion = { Test-PuertoSSH } },
    @{ Nombre = 'Puertos';   Funcion = { Test-PuertosExpuestos } },
    @{ Nombre = 'Tareas';    Funcion = { Test-TareasProgramadas } },
    @{ Nombre = 'Defender';  Funcion = { Test-Defender } },
    @{ Nombre = 'Firewall';  Funcion = { Test-Firewall } },
    @{ Nombre = 'RDP/WinRM'; Funcion = { Test-AccesoRemoto } },
    @{ Nombre = 'Identidad'; Funcion = { Test-Identidad } }
)

foreach ($c in $chequeos) {
    try {
        $hallazgos += & $c.Funcion
    } catch {
        $hallazgos += New-Hallazgo 'Aviso' $c.Nombre "No se pudo evaluar: $($_.Exception.Message)"
    }
}

$criticos = @($hallazgos | Where-Object { $_.Severidad -eq 'Critico' })
$avisos   = @($hallazgos | Where-Object { $_.Severidad -eq 'Aviso' })
$infos    = @($hallazgos | Where-Object { $_.Severidad -eq 'Info' })

foreach ($h in $infos)    { Write-Output "[i] $($h.Area): $($h.Detalle)" }
foreach ($h in $avisos)   { Write-Output "[!] $($h.Area): $($h.Detalle)" }
foreach ($h in $criticos) { Write-Output "[X] $($h.Area): $($h.Detalle)" }

# --- Event Log ---
$partes = @()
if ($criticos.Count -gt 0) {
    $partes += "CRITICOS ($($criticos.Count)):"
    $criticos | ForEach-Object { $partes += " - $($_.Area): $($_.Detalle)" }
}
if ($avisos.Count -gt 0) {
    $partes += "AVISOS ($($avisos.Count)):"
    $avisos | ForEach-Object { $partes += " - $($_.Area): $($_.Detalle)" }
}
if ($partes.Count -eq 0) { $partes = @('Radar OK: sin hallazgos.') }
$mensajeEvento = $partes -join "`n"

$eventId = 1000
$tipoEvento = 'Information'
if ($criticos.Count -gt 0) {
    $eventId = 1001
    $tipoEvento = 'Error'
} elseif ($avisos.Count -gt 0) {
    $eventId = 1002
    $tipoEvento = 'Warning'
}

# --- Informe en archivo (el popup lo abre con un click) ---
$resumen = "$($criticos.Count) criticos, $($avisos.Count) avisos, $($infos.Count) informativos"
$rutaInforme = Write-InformeEjecucion -Mensaje $mensajeEvento -EventId $eventId `
    -TipoEvento $tipoEvento -Resumen $resumen -Hallazgos $hallazgos

$mensajeConRuta = $mensajeEvento
if ($rutaInforme) { $mensajeConRuta += "`n`nInforme completo: $rutaInforme" }
Write-LogSeguridad -Mensaje $mensajeConRuta -Tipo $tipoEvento -Id $eventId

# --- Popup ---
$mostrarPopup = $false
if ($criticos.Count -gt 0) {
    $mostrarPopup = $true
} elseif ($avisos.Count -gt 0 -and -not $script:Config.PopupSoloCritico) {
    $mostrarPopup = $true
}
if ($SinPopup) { $mostrarPopup = $false }

if ($mostrarPopup) {
    $lineasPopup = @()
    if ($criticos.Count -gt 0) {
        $lineasPopup += "CRITICOS ($($criticos.Count)):"
        $criticos | ForEach-Object { $lineasPopup += " - $($_.Area): $($_.Detalle)" }
        $lineasPopup += ''
    }
    if ($avisos.Count -gt 0) {
        $lineasPopup += "AVISOS ($($avisos.Count)):"
        $avisos | ForEach-Object { $lineasPopup += " - $($_.Area): $($_.Detalle)" }
        $lineasPopup += ''
    }

    # Techo defensivo: el detalle completo queda en el archivo.
    if ($lineasPopup.Count -gt 300) {
        $resto = $lineasPopup.Count - 299
        $lineasPopup = @($lineasPopup[0..298]) + "... y $resto lineas mas (ver informe completo)"
    }

    $textoPopup = ($lineasPopup -join "`n") + "`nRevisar y actuar."
    Show-PopupRadar -Titulo 'RADAR DE SEGURIDAD' -Texto $textoPopup -RutaInforme $rutaInforme
}

# --- Consola ---
if ($criticos.Count -eq 0 -and $avisos.Count -eq 0) {
    Write-Output "RADAR OK: sin amenazas detectadas ($($infos.Count) informativos)."
} else {
    Write-Output "RADAR: $($criticos.Count) criticos, $($avisos.Count) avisos. Evento ID $eventId."
}
if ($rutaInforme) { Write-Output "Informe: $rutaInforme" }

```

## Apendice B - Configuracion (`Radar.config.psd1`)

```powershell
# ==========================================
# Radar.config.psd1
# Configuracion del Radar de Seguridad.
# Si el archivo no existe, el script usa estos mismos valores.
# ==========================================
@{
    # $true  = solo los hallazgos CRITICOS abren popup (recomendado, evita fatiga)
    # $false = los AVISOS tambien abren popup
    PopupSoloCritico = $true

    # Cuantos informes se conservan en logs\ (cada corrida deja un .log con el
    # detalle completo). 0 = sin limite.
    RetencionInformes = 60

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
```
