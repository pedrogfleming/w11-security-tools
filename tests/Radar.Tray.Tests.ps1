# ==========================================
# Tests de las funciones de datos del dashboard (Radar-Tray.ps1).
# No abre ventanas: solo parseo de informes (sueltos y archivados).
# ==========================================

BeforeAll {
    $script:trayPath = (Resolve-Path (Join-Path $PSScriptRoot '..\Radar-Tray.ps1')).Path

    $tokens = $null
    $errores = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:trayPath, [ref]$tokens, [ref]$errores)

    if ($errores.Count -gt 0) {
        throw "Radar-Tray.ps1 tiene $($errores.Count) errores de sintaxis."
    }

    foreach ($nombre in @('ConvertTo-InformeRadar', 'Read-InformesRadar', 'Read-InformesArchivo', 'Get-InformesDashboard', 'Get-TareasRadar')) {
        $fn = $ast.FindAll({
                param($nodo)
                $nodo -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $nodo.Name -eq $nombre
            }, $true)[0]

        if (-not $fn) { throw "No se encontro la funcion '$nombre' en Radar-Tray.ps1." }
        . ([scriptblock]::Create($fn.Extent.Text))
    }

    $script:PatronTarea = 'Seguridad - *'
    $script:TareaDash = 'Seguridad - Dashboard Radar'
    $script:CacheArchivo = $null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    function Get-TextoLogPrueba {
        param(
            [int]$Criticos = 0,
            [int]$Avisos = 0,
            [string]$Fecha = '01/01/2026 10:00:00',
            [string]$Elevado = 'Si'
        )
        @(
            '=================================================================='
            ' RADAR DE SEGURIDAD - INFORME DE EJECUCION'
            '=================================================================='
            "Fecha     : $Fecha"
            'Equipo    : TEST'
            'Usuario   : tester'
            "Elevado   : $Elevado"
            'Evento    : Application / Seguridad-Port22 / ID 1001 (Error)'
            "Resultado : $Criticos criticos, $Avisos avisos, 0 informativos"
            ''
        ) -join "`r`n"
    }

    function New-LogPrueba {
        param(
            [string]$Dir,
            [string]$NombreArchivo,
            [int]$Criticos = 0,
            [int]$Avisos = 0,
            [string]$Fecha = '01/01/2026 10:00:00',
            [string]$Elevado = 'Si',
            [datetime]$FechaArchivo = (Get-Date)
        )
        $ruta = Join-Path $Dir $NombreArchivo
        Set-Content -Path $ruta -Value (Get-TextoLogPrueba -Criticos $Criticos -Avisos $Avisos -Fecha $Fecha -Elevado $Elevado) -Encoding UTF8
        (Get-Item $ruta).LastWriteTime = $FechaArchivo
        return $ruta
    }

    function New-ZipPrueba {
        param(
            [string]$Dir,
            [string]$NombreZip,
            [hashtable]$Entradas,
            [datetime]$FechaArchivo = (Get-Date)
        )
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        $ruta = Join-Path $Dir $NombreZip

        $zip = [System.IO.Compression.ZipFile]::Open($ruta, 'Create')
        try {
            foreach ($k in $Entradas.Keys) {
                $entrada = $zip.CreateEntry($k)
                $w = New-Object System.IO.StreamWriter($entrada.Open())
                try { $w.Write($Entradas[$k]) } finally { $w.Dispose() }
            }
        } finally {
            $zip.Dispose()
        }
        (Get-Item $ruta).LastWriteTime = $FechaArchivo
        return $ruta
    }
}

Describe 'Informes del dashboard' {

    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ("radar-tray-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:dirLogs = $script:dir
        $script:CacheArchivo = $null
    }

    AfterEach {
        if ($script:dir -and (Test-Path $script:dir)) {
            Remove-Item -Path $script:dir -Recurse -Force
        }
    }

    Context 'informes sueltos' {

        It 'devuelve lista vacia si el directorio no existe' {
            @(Read-InformesRadar -Directorio (Join-Path $script:dir 'nada') -Maximo 10).Count | Should -Be 0
        }

        It 'lee los campos del encabezado' {
            New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260101-100000.log' -Criticos 2 -Avisos 3 | Out-Null

            $r = @(Read-InformesRadar -Directorio $script:dir -Maximo 10)

            $r.Count | Should -Be 1
            $r[0].Criticos | Should -Be 2
            $r[0].Avisos | Should -Be 3
            $r[0].Informativos | Should -Be 0
            $r[0].Elevado | Should -Be 'Si'
            $r[0].Equipo | Should -Be 'TEST'
            $r[0].Evento | Should -Match 'ID 1001'
            $r[0].Archivado | Should -BeFalse
            $r[0].Entrada | Should -Be ''
            $r[0].Fecha.ToString('dd/MM/yyyy HH:mm') | Should -Be '01/01/2026 10:00'
            (Split-Path $r[0].Ruta -Leaf) | Should -Be 'radar-20260101-100000.log'
        }

        It 'ordena del mas nuevo al mas viejo' {
            New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260101-080000.log' -FechaArchivo (Get-Date).AddMinutes(-30) | Out-Null
            New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260102-080000.log' -FechaArchivo (Get-Date).AddMinutes(-20) | Out-Null
            New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260103-080000.log' -FechaArchivo (Get-Date).AddMinutes(-10) | Out-Null

            $r = @(Read-InformesRadar -Directorio $script:dir -Maximo 10)

            $r.Count | Should -Be 3
            (Split-Path $r[0].Ruta -Leaf) | Should -Be 'radar-20260103-080000.log'
            (Split-Path $r[2].Ruta -Leaf) | Should -Be 'radar-20260101-080000.log'
        }

        It 'respeta el maximo pedido' {
            1..5 | ForEach-Object {
                New-LogPrueba -Dir $script:dir -NombreArchivo ("radar-2026010{0}-090000.log" -f $_) | Out-Null
            }

            @(Read-InformesRadar -Directorio $script:dir -Maximo 2).Count | Should -Be 2
        }

        It 'no falla con un informe corrupto o vacio' {
            Set-Content -Path (Join-Path $script:dir 'radar-20260101-000000.log') -Value 'basura' -Encoding ASCII
            New-Item -ItemType File -Path (Join-Path $script:dir 'radar-20260101-000001.log') | Out-Null

            $r = @(Read-InformesRadar -Directorio $script:dir -Maximo 10)

            $r.Count | Should -Be 2
            $r[0].Criticos | Should -Be 0
            $r[0].Avisos | Should -Be 0
            $r[0].Ruta | Should -Exist
        }

        It 'ignora archivos que no son informes' {
            New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260101-100000.log' -Criticos 1 | Out-Null
            Set-Content -Path (Join-Path $script:dir 'otra-cosa.log') -Value 'x' -Encoding ASCII
            Set-Content -Path (Join-Path $script:dir 'radar.txt') -Value 'x' -Encoding ASCII

            @(Read-InformesRadar -Directorio $script:dir -Maximo 10).Count | Should -Be 1
        }
    }

    Context 'informes archivados' {

        It 'lee los informes de un zip mensual' {
            $zip = New-ZipPrueba -Dir (Join-Path $script:dir 'archivo') -NombreZip 'radar-2026-01.zip' -Entradas @{
                'radar-20260105-100000.log' = (Get-TextoLogPrueba -Criticos 1 -Fecha '05/01/2026 10:00:00')
                'radar-20260106-100000.log' = (Get-TextoLogPrueba -Avisos 2 -Fecha '06/01/2026 10:00:00')
            }

            $r = @(Read-InformesArchivo -Directorio (Join-Path $script:dir 'archivo'))

            $r.Count | Should -Be 2
            @($r | Where-Object { $_.Archivado }).Count | Should -Be 2
            ($r | Where-Object { $_.Criticos -eq 1 }).Entrada | Should -Be 'radar-20260105-100000.log'
            ($r | Where-Object { $_.Criticos -eq 1 }).Ruta | Should -Be $zip
            ($r | Where-Object { $_.Avisos -eq 2 }).Fecha.ToString('dd/MM/yyyy HH:mm') | Should -Be '06/01/2026 10:00'
        }

        It 'ignora entradas que no son informes' {
            New-ZipPrueba -Dir (Join-Path $script:dir 'archivo') -NombreZip 'radar-2026-01.zip' -Entradas @{
                'leeme.txt'                 = 'hola'
                'radar-20260105-100000.log' = (Get-TextoLogPrueba -Criticos 1)
            } | Out-Null

            @(Read-InformesArchivo -Directorio (Join-Path $script:dir 'archivo')).Count | Should -Be 1
        }

        It 'devuelve vacio si no hay carpeta de archivo' {
            @(Read-InformesArchivo -Directorio (Join-Path $script:dir 'archivo')).Count | Should -Be 0
        }

        It 'no falla con un zip corrupto' {
            New-Item -ItemType Directory -Path (Join-Path $script:dir 'archivo') -Force | Out-Null
            Set-Content -Path (Join-Path $script:dir 'archivo\radar-2026-02.zip') -Value 'no soy un zip' -Encoding ASCII

            { Read-InformesArchivo -Directorio (Join-Path $script:dir 'archivo') 3>$null } | Should -Not -Throw
        }
    }

    Context 'dashboard combinado' {

        It 'junta sueltos y archivados, del mas nuevo al mas viejo' {
            New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260310-100000.log' -Fecha '10/03/2026 10:00:00' -Criticos 1 | Out-Null
            New-LogPrueba -Dir $script:dir -NombreArchivo 'radar-20260311-100000.log' -Fecha '11/03/2026 10:00:00' | Out-Null
            New-ZipPrueba -Dir (Join-Path $script:dir 'archivo') -NombreZip 'radar-2026-01.zip' -Entradas @{
                'radar-20260105-100000.log' = (Get-TextoLogPrueba -Avisos 1 -Fecha '05/01/2026 10:00:00')
            } | Out-Null

            $r = @(Get-InformesDashboard -Maximo 50)

            $r.Count | Should -Be 3
            $r[0].Fecha.ToString('dd/MM/yyyy HH:mm') | Should -Be '11/03/2026 10:00'
            $r[1].Fecha.ToString('dd/MM/yyyy HH:mm') | Should -Be '10/03/2026 10:00'
            $r[2].Archivado | Should -BeTrue
            $r[2].Fecha.ToString('dd/MM/yyyy HH:mm') | Should -Be '05/01/2026 10:00'
        }

        It 'respeta el maximo combinado' {
            1..4 | ForEach-Object {
                New-LogPrueba -Dir $script:dir -NombreArchivo ("radar-2026030{0}-100000.log" -f $_) -Fecha ("0{0}/03/2026 10:00:00" -f $_) | Out-Null
            }
            New-ZipPrueba -Dir (Join-Path $script:dir 'archivo') -NombreZip 'radar-2026-01.zip' -Entradas @{
                'radar-20260101-100000.log' = (Get-TextoLogPrueba -Fecha '01/01/2026 10:00:00')
                'radar-20260102-100000.log' = (Get-TextoLogPrueba -Fecha '02/01/2026 10:00:00')
            } | Out-Null

            @(Get-InformesDashboard -Maximo 3).Count | Should -Be 3
        }

        It 'usa cache y la invalida cuando aparece un zip nuevo' {
            $dirArchivo = Join-Path $script:dir 'archivo'
            New-ZipPrueba -Dir $dirArchivo -NombreZip 'radar-2026-01.zip' -Entradas @{
                'radar-20260101-100000.log' = (Get-TextoLogPrueba -Fecha '01/01/2026 10:00:00')
            } | Out-Null

            @(Get-InformesDashboard -Maximo 50).Count | Should -Be 1

            New-ZipPrueba -Dir $dirArchivo -NombreZip 'radar-2026-02.zip' -Entradas @{
                'radar-20260201-100000.log' = (Get-TextoLogPrueba -Fecha '01/02/2026 10:00:00')
            } | Out-Null

            @(Get-InformesDashboard -Maximo 50).Count | Should -Be 2
        }
    }
}
