﻿# PSake makes variables declared here available in other scriptblocks
# Init some things
Properties {
    # Find the build folder based on build system
    $ProjectRoot = $ENV:BHProjectPath
    if(-not $ProjectRoot)
    {
        $ProjectRoot = $PSScriptRoot
    }

    $Verbose = @{}
    if($ENV:BHCommitMessage -match "!verbose")
    {
        $Verbose = @{Verbose = $True}
    }
}

Task Default -Depends Deploy

Task Init {
    '----------------------------------------------------------------------'
    Set-Location $ProjectRoot
    "Build System Details:"
    Get-Item ENV:BH*
    $PSVersionTable
    "`n"
}

Task Test -Depends Init  {
    '----------------------------------------------------------------------'
    $Timestamp = Get-date -uformat "%Y%m%d-%H%M%S"
    $PSVersion = $PSVersionTable.PSVersion.Major
    $TestFile = "TestResults_PS$PSVersion`_$TimeStamp.xml"
        
    "`n`tSTATUS: Testing with PowerShell $PSVersion"

    # Gather test results. Store them in a variable and file
    $CodeFiles = (Get-ChildItem $ENV:BHModulePath -Recurse -Include '*.ps1').FullName
    $Script:TestResults = Invoke-Pester -Path (Join-Path $ProjectRoot '/Tests') -CodeCoverage $CodeFiles -PassThru -OutputFormat NUnitXml -OutputFile (Join-Path $ProjectRoot "/$TestFile") -ExcludeTag Integration

    # In Appveyor?  Upload our tests! #Abstract this into a function?
    If($ENV:BHBuildSystem -eq 'AppVeyor')
    {
        (New-Object 'System.Net.WebClient').UploadFile(
            "https://ci.appveyor.com/api/testresults/nunit/$($env:APPVEYOR_JOB_ID)",
            (Join-Path $ProjectRoot "/$TestFile") )
    }

    Remove-Item (Join-Path $ProjectRoot "/$TestFile") -Force -ErrorAction SilentlyContinue

    # Failed tests?
    # Need to tell psake or it will proceed to the deployment. Danger!
    if($Script:TestResults.FailedCount -gt 0)
    {
        Write-Error "Failed '$($Script:TestResults.FailedCount)' tests, build failed"
    }
    "`n"
}

Task Build -Depends Test {
    '----------------------------------------------------------------------'
    #Update readme.md with Code Coverage result
    function Update-CodeCoveragePercent {
        [cmdletbinding(supportsshouldprocess)]
        param(
            [int]
            $CodeCoverage = 0,
            
            [string]
            $TextFilePath = (Join-Path $Env:BHProjectPath 'README.md')
        )
    
        $BadgeColor = switch ($CodeCoverage) {
            {$_ -in 90..100} { 'brightgreen' }
            {$_ -in 75..89}  { 'yellow' }
            {$_ -in 60..74}  { 'orange' }
            default          { 'red' }
        }
    
        if ($PSCmdlet.ShouldProcess($TextFilePath)) {
            $ReadmeContent = (Get-Content $TextFilePath)
            $ReadmeContent = $ReadmeContent -replace "!\[Test Coverage\].+\)", "![Test Coverage](https://img.shields.io/badge/coverage-$CodeCoverage%25-$BadgeColor.svg?maxAge=60)" 
            $ReadmeContent | Set-Content -Path $TextFilePath
        }
    }
    
    $CoveragePercent = [math]::floor(100 - (($Script:TestResults.CodeCoverage.NumberOfCommandsMissed / $Script:TestResults.CodeCoverage.NumberOfCommandsAnalyzed) * 100))

    "`n`tSTATUS: Running Update-CodeCoveragePercent to update Readme.md with $CoveragePercent% code coverage badge"
    Update-CodeCoveragePercent -CodeCoverage $CoveragePercent
    "`n"
}

Task Deploy -Depends Build {
    '----------------------------------------------------------------------'
    #Skip deployment if we're testing on core.
    if ($psversiontable.psedition -ne 'Core'){

        # Update Manifest version number
        $ManifestPath = $Env:BHPSModuleManifest
        
        if (-Not $env:APPVEYOR_BUILD_VERSION) {
            $Manifest = Test-ModuleManifest -Path $manifestPath
            [System.Version]$Version = $Manifest.Version
            [String]$NewVersion = New-Object -TypeName System.Version -ArgumentList ($Version.Major, $Version.Minor, $Version.Build, ($Version.Revision+1))
        } 
        else {
            $NewVersion = $env:APPVEYOR_BUILD_VERSION
        }
        "New Version: $NewVersion"

        $FunctionList = @((Get-ChildItem -File -Recurse -Path (Join-Path $Env:BHModulePath '/Public')).BaseName)

        Update-ModuleManifest -Path $ManifestPath -ModuleVersion $NewVersion -FunctionsToExport $functionList
        
        $Params = @{
            Path = $ProjectRoot
            Force = $true
            Recurse = $false # We keep psdeploy artifacts, avoid deploying those : )
        }
        Invoke-PSDeploy @Verbose @Params
    }
}