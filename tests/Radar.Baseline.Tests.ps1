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

    foreach ($nombre in @('Read-Baseline', 'Write-Baseline', 'Compare-ConBaseline')) {
        if (-not (Get-Command $nombre -ErrorAction SilentlyContinue)) {
            throw "No se encontro la funcion '$nombre' en Check-Port22.ps1."
        }
    }
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
