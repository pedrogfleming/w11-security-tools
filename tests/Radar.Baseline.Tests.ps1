# ==========================================
# Tests de las funciones de linea base del radar.
# No ejecuta el radar completo: extrae las funciones del script con el AST,
# asi se pueden probar sin tocar el sistema ni el Visor de Eventos.
# ==========================================

BeforeAll {
    $script:radarPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Check-Port22.ps1')).Path

    $tokens = $null
    $errores = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:radarPath, [ref]$tokens, [ref]$errores)

    if ($errores.Count -gt 0) {
        throw "Check-Port22.ps1 tiene $($errores.Count) errores de sintaxis."
    }

    $funciones = $ast.FindAll({
        param($nodo)
        $nodo -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    foreach ($f in $funciones) {
        . ([scriptblock]::Create($f.Extent.Text))
    }

    foreach ($nombre in @('Read-Baseline', 'Write-Baseline', 'Compare-ConBaseline', 'Write-InformeEjecucion')) {
        if (-not (Get-Command $nombre -ErrorAction SilentlyContinue)) {
            throw "No se encontro la funcion '$nombre' en Check-Port22.ps1."
        }
    }

    # Variables de script que usan las funciones extraidas.
    $script:logsDir = Join-Path ([System.IO.Path]::GetTempPath()) 'radar-test-logs'
    $script:logType = 'Application'
    $script:eventoLog = 'Seguridad-Port22'
    $script:EsAdmin = $true
    $script:Config = @{ RetencionInformes = 60; AbrirDetalleCon = '' }
}

Describe 'Lineas base del radar' {

    BeforeEach {
        $script:baseDir = Join-Path ([System.IO.Path]::GetTempPath()) ("radar-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:baseDir -Force | Out-Null
        $script:AprobarTodo = $false
    }

    AfterEach {
        if ($script:baseDir -and (Test-Path $script:baseDir)) {
            Remove-Item -Path $script:baseDir -Recurse -Force
        }
    }

    Context 'primera corrida' {

        It 'crea la baseline sin alertar' {
            $r = Compare-ConBaseline -Nombre 'vacia' -Actual @()

            $r.Primera | Should -BeTrue
            $r.Aprobado | Should -BeFalse
            $r.Nuevos.Count | Should -Be 0
            (Join-Path $script:baseDir 'vacia.json') | Should -Exist
        }

        It 'guarda los items actuales ordenados' {
            Compare-ConBaseline -Nombre 'items' -Actual @('b', 'a') | Out-Null

            $guardado = Get-Content (Join-Path $script:baseDir 'items.json') -Raw | ConvertFrom-Json
            (@($guardado.items) -join ',') | Should -Be 'a,b'
        }
    }

    Context 'baseline vacia' {

        BeforeEach {
            Compare-ConBaseline -Nombre 'vacia' -Actual @() | Out-Null
        }

        It 'no falla al comparar vacia contra vacia' {
            $r = Compare-ConBaseline -Nombre 'vacia' -Actual @()

            $r.Primera | Should -BeFalse
            $r.Nuevos.Count | Should -Be 0
        }

        It 'detecta el primer item nuevo' {
            $r = Compare-ConBaseline -Nombre 'vacia' -Actual @('Ruta|C:\x')

            $r.Nuevos.Count | Should -Be 1
            $r.Nuevos[0] | Should -Be 'Ruta|C:\x'
        }
    }

    Context 'baseline con contenido' {

        BeforeEach {
            Write-Baseline -Nombre 'dos' -Items @('a', 'b')
        }

        It 'no reporta nada si el contenido es el mismo' {
            $r = Compare-ConBaseline -Nombre 'dos' -Actual @('b', 'a')
            $r.Nuevos.Count | Should -Be 0
        }

        It 'reporta solo las altas' {
            $r = Compare-ConBaseline -Nombre 'dos' -Actual @('a', 'b', 'c')

            $r.Nuevos.Count | Should -Be 1
            $r.Nuevos[0] | Should -Be 'c'
        }

        It 'no actualiza la baseline cuando hay novedades' {
            Compare-ConBaseline -Nombre 'dos' -Actual @('a', 'b', 'c') | Out-Null

            $guardado = Get-Content (Join-Path $script:baseDir 'dos.json') -Raw | ConvertFrom-Json
            @($guardado.items).Count | Should -Be 2
        }

        It 'ignora las bajas y refresca la baseline' {
            $r = Compare-ConBaseline -Nombre 'dos' -Actual @('a')

            $r.Nuevos.Count | Should -Be 0
            $guardado = Get-Content (Join-Path $script:baseDir 'dos.json') -Raw | ConvertFrom-Json
            (@($guardado.items) -join ',') | Should -Be 'a'
        }
    }

    Context 'aprobacion' {

        BeforeEach {
            Write-Baseline -Nombre 'apro' -Items @('a')
        }

        It 'con -Aprobar actualiza y no vuelve a alertar' {
            $r = Compare-ConBaseline -Nombre 'apro' -Actual @('a', 'b') -Aprobar

            $r.Aprobado | Should -BeTrue
            $r.Nuevos.Count | Should -Be 1

            $siguiente = Compare-ConBaseline -Nombre 'apro' -Actual @('a', 'b')
            $siguiente.Nuevos.Count | Should -Be 0
        }
    }

    Context 'archivos invalidos' {

        It 'regenera una baseline con JSON corrupto sin alertar' {
            Set-Content -Path (Join-Path $script:baseDir 'roto.json') -Value '{ esto no es json' -Encoding UTF8

            $r = Compare-ConBaseline -Nombre 'roto' -Actual @('z') 3>$null

            $r.Primera | Should -BeTrue
            $r.Nuevos.Count | Should -Be 0

            $guardado = Get-Content (Join-Path $script:baseDir 'roto.json') -Raw | ConvertFrom-Json
            (@($guardado.items) -join ',') | Should -Be 'z'
        }

        It 'ignora items nulos en el JSON' {
            @{ items = @($null) } | ConvertTo-Json | Set-Content -Path (Join-Path $script:baseDir 'nulos.json') -Encoding UTF8

            { Compare-ConBaseline -Nombre 'nulos' -Actual @() } | Should -Not -Throw
        }
    }
}

Describe 'Normalizacion de claves' {

    Context 'ConvertTo-ClaveEstable' {

        It 'reemplaza GUIDs por un marcador' {
            ConvertTo-ClaveEstable -Texto '{A799B4F5-3FC8-45FC-B49C-C8E8FEB9D490}' |
                Should -Be '{GUID}'
        }

        It 'reemplaza GUIDs sin llaves (formato HNS)' {
            ConvertTo-ClaveEstable -Texto 'C08CB7B8-9B3C-408E-8E30-5E16A3AEB445' |
                Should -Be '{GUID}'
        }

        It 'normaliza el nombre completo de una regla HNS' {
            ConvertTo-ClaveEstable -Texto 'HNS Container Networking - DNS (UDP-In) - C08CB7B8-9B3C-408E-8E30-5E16A3AEB445 - 0' |
                Should -Be 'HNS Container Networking - DNS (UDP-In) - {GUID} - <ID>'
        }

        It 'no toca un nombre con un numero final comun' {
            ConvertTo-ClaveEstable -Texto 'Mi Regla - 2' | Should -Be 'Mi Regla - 2'
        }

        It 'reemplaza IDs numericos largos' {
            ConvertTo-ClaveEstable -Texto 'SoftLandingTriggerTask-128000000001615609-render' |
                Should -Be 'SoftLandingTriggerTask-<ID>-render'
        }

        It 'deja intactos los nombres estables' {
            ConvertTo-ClaveEstable -Texto '\Microsoft\Windows\Defrag\ScheduledDefrag' |
                Should -Be '\Microsoft\Windows\Defrag\ScheduledDefrag'
        }

        It 'no toca los SIDs de usuario' {
            $sid = '\SoftLanding\S-1-5-21-2379985883-2381256654-1499518547-1001\'
            ConvertTo-ClaveEstable -Texto $sid | Should -Be $sid
        }

        It 'devuelve cadena vacia para null o espacios' {
            ConvertTo-ClaveEstable -Texto '' | Should -Be ''
            ConvertTo-ClaveEstable -Texto '   ' | Should -Be ''
        }
    }

    Context 'Test-Ignorado' {

        It 'acepta comodines' {
            Test-Ignorado -Valores @('\SoftLanding\S-1-5-21-1\') -Patrones @('\SoftLanding\*') |
                Should -BeTrue
        }

        It 'no ignora cuando no coincide' {
            Test-Ignorado -Valores @('\Microsoft\Windows\Defrag\') -Patrones @('\SoftLanding\*') |
                Should -BeFalse
        }

        It 'compara contra varios valores' {
            Test-Ignorado -Valores @('{GUID}', 'Microsoft Edge (mDNS-In)') -Patrones @('Firefox*', 'Microsoft Edge*') |
                Should -BeTrue
        }

        It 'ignora patrones vacios o nulos' {
            Test-Ignorado -Valores @('x') -Patrones @('', $null) | Should -BeFalse
        }
    }
}

Describe 'Informe de ejecucion' {

    BeforeEach {
        $script:dirInformes = Join-Path ([System.IO.Path]::GetTempPath()) ("radar-informes-" + [guid]::NewGuid().ToString('N'))
        $script:Config = @{ RetencionInformes = 60; AbrirDetalleCon = '' }
    }

    AfterEach {
        if ($script:dirInformes -and (Test-Path $script:dirInformes)) {
            Remove-Item -Path $script:dirInformes -Recurse -Force
        }
    }

    It 'crea el archivo y devuelve la ruta' {
        $ruta = Write-InformeEjecucion -Mensaje 'Radar OK: sin hallazgos.' `
            -EventId 1000 -TipoEvento Information -Resumen '0 criticos, 0 avisos' `
            -Directorio $script:dirInformes

        $ruta | Should -Exist
        (Split-Path $ruta -Leaf) | Should -Match '^radar-\d{8}-\d{6}\.log$'
    }

    It 'incluye el evento, el resumen y el mensaje' {
        $ruta = Write-InformeEjecucion -Mensaje 'CRITICOS (1):' `
            -EventId 1001 -TipoEvento Error -Resumen '1 criticos, 0 avisos' `
            -Directorio $script:dirInformes

        $texto = Get-Content $ruta -Raw
        $texto | Should -Match 'ID 1001 \(Error\)'
        $texto | Should -Match '1 criticos, 0 avisos'
        $texto | Should -Match 'CRITICOS \(1\):'
    }

    It 'agrupa los hallazgos por severidad' {
        $hallazgos = @(
            [pscustomobject]@{ Severidad = 'Aviso';   Area = 'Firewall'; Detalle = 'aviso uno' },
            [pscustomobject]@{ Severidad = 'Critico'; Area = 'SSH';      Detalle = 'critico uno' },
            [pscustomobject]@{ Severidad = 'Info';    Area = 'Firewall'; Detalle = 'info uno' }
        )

        $ruta = Write-InformeEjecucion -Hallazgos $hallazgos -Directorio $script:dirInformes
        $texto = Get-Content $ruta -Raw

        $texto | Should -Match 'CRITICOS \(1\)\r?\n  - SSH: critico uno'
        $texto | Should -Match 'AVISOS \(1\)\r?\n  - Firewall: aviso uno'
        $texto | Should -Match 'INFORMATIVOS \(1\)\r?\n  - Firewall: info uno'
        ($texto.IndexOf('CRITICOS')) | Should -BeLessThan ($texto.IndexOf('AVISOS'))
    }

    It 'marca el resumen como sin hallazgos cuando todo es informativo' {
        $ruta = Write-InformeEjecucion -Hallazgos @(
            [pscustomobject]@{ Severidad = 'Info'; Area = 'SSH'; Detalle = 'sin sshd' }
        ) -Directorio $script:dirInformes

        Get-Content $ruta -Raw | Should -Match 'Sin hallazgos'
    }

    It 'no pisa un informe existente de la misma corrida' {
        $a = Write-InformeEjecucion -Mensaje 'uno' -Directorio $script:dirInformes
        $b = Write-InformeEjecucion -Mensaje 'dos' -Directorio $script:dirInformes

        $a | Should -Not -Be $b
        $a | Should -Exist
        $b | Should -Exist
    }

    It 'respeta la retencion configurada' {
        New-Item -ItemType Directory -Path $script:dirInformes -Force | Out-Null
        1..5 | ForEach-Object {
            $f = Join-Path $script:dirInformes ("radar-2026010{0}-000000.log" -f $_)
            Set-Content -Path $f -Value 'viejo' -Encoding ASCII
            (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-10 + $_)
        }
        $script:Config.RetencionInformes = 2

        Write-InformeEjecucion -Mensaje 'nuevo' -Directorio $script:dirInformes | Out-Null

        @(Get-ChildItem -Path $script:dirInformes -Filter 'radar-*.log').Count | Should -Be 2
    }

    It 'no falla si el directorio no existe' {
        $dir = Join-Path $script:dirInformes 'sub'
        { Write-InformeEjecucion -Mensaje 'x' -Directorio $dir } | Should -Not -Throw
        @(Get-ChildItem -Path $dir -Filter 'radar-*.log').Count | Should -Be 1
    }
}

