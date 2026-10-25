# ==========================================
# SCRIPT: Radar de Seguridad Diario  (fase 1)
# Chequeos: SSH, puertos expuestos, tareas nuevas,
#           Defender, Firewall, RDP/WinRM, Identidad
#
# Uso:
#   .\Check-Port22.ps1                  # corrida normal
#   .\Check-Port22.ps1 -SinPopup        # prueba: no muestra popup
#   .\Check-Port22.ps1 -AprobarBaselines # acepta TODAS las novedades como conocidas
#   .\Check-Port22.ps1 -AprobarTareas    # solo tareas programadas
# ==========================================

param(
    [switch]$AprobarTareas,
    [switch]$AprobarBaselines,
    [switch]$SinPopup
)

$eventoLog      = "Seguridad-Port22"
$logType        = "Application"
$script:baseDir = Join-Path $PSScriptRoot "baseline"
$refTareasTxt   = Join-Path $PSScriptRoot "tareas_baseline.txt"

$script:AprobarTodo   = [bool]$AprobarBaselines
$script:AprobarTareas = ([bool]$AprobarTareas -or [bool]$AprobarBaselines)

# ---------------------------------------------------------
# Configuracion (Radar.config.psd1) con defaults
# ---------------------------------------------------------
$config = @{
    PopupSoloCritico = $true
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

    $t = $Texto -replace '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}', '{GUID}'
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

if ($criticos.Count -gt 0) {
    Write-LogSeguridad -Mensaje $mensajeEvento -Tipo Error -Id 1001
} elseif ($avisos.Count -gt 0) {
    Write-LogSeguridad -Mensaje $mensajeEvento -Tipo Warning -Id 1002
} else {
    Write-LogSeguridad -Mensaje $mensajeEvento -Tipo Information -Id 1000
}

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
        $lineasPopup += "CRITICOS:"
        $criticos | ForEach-Object { $lineasPopup += " - $($_.Area): $($_.Detalle)" }
    }
    if ($avisos.Count -gt 0) {
        $lineasPopup += ""
        $lineasPopup += "Avisos: $($avisos.Count) (ver Visor de Eventos, ID 1002)"
    }
    if ($lineasPopup.Count -gt 18) {
        $resto = $lineasPopup.Count - 17
        $lineasPopup = @($lineasPopup[0..16]) + "... y $resto mas (ver Visor de Eventos)"
    }

    $texto = ($lineasPopup -join "`n") + "`n`nRevisar y actuar."
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $texto,
        "RADAR DE SEGURIDAD",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
}

# --- Consola ---
if ($criticos.Count -eq 0 -and $avisos.Count -eq 0) {
    Write-Output "RADAR OK: sin amenazas detectadas ($($infos.Count) informativos)."
} else {
    Write-Output "RADAR: $($criticos.Count) criticos, $($avisos.Count) avisos. Evento ID $(if ($criticos.Count) { 1001 } else { 1002 })."
}
