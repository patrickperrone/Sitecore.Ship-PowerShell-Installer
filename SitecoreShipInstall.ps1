# Specify a path to the .config file if you do not wish to put the .config file in the same directory as the script
$configPath = ""
$scriptDir = Split-Path (Resolve-Path $myInvocation.MyCommand.Path)
$workingDir = Join-Path $scriptDir -ChildPath "temp"

function Write-Message([xml]$config, [string]$message, [string]$messageColor, [bool]$logOnly=$FALSE)
{
    $installPath = $config.InstallSettings.SitecoreInstanceRoot.Trim()
    $logFileName = $config.InstallSettings.LogFileName.Trim()
    $logPath = Join-path $installPath -ChildPath $logFileName

    # Write message to log file
    if (!([string]::IsNullOrEmpty($logFileName)))
    {
        Add-Content $logPath $message
    }

    # Write message to screen
    if (!($logOnly))
    {
        Write-Host $message -ForegroundColor $messageColor;
    }
}

function Get-ConfigOption([xml]$config, [string]$optionName)
{
    $optionValue = $FALSE
    $nodeValue = $config.InstallSettings.SelectSingleNode($optionName).InnerText
    if (!([string]::IsNullOrEmpty($nodeValue)))
    {
        $optionValue = [System.Convert]::ToBoolean($nodeValue)
    }
    return $optionValue
}

function Read-InstallConfigFile([string]$configPath)
{
    if ([string]::IsNullOrEmpty($configPath))
    {
        [xml]$configXml = Get-Content ($scriptDir + "\SitecoreShipInstall.config")
    }
    else
    {
        if (Test-Path $configPath)
        {
            [xml]$configXml = Get-Content ($configPath)
        }
        else
        {
            Write-Host "Could not find configuration file at specified path: $confgPath" -ForegroundColor Red
        }
    }

    return $configXml
}

function Get-WebRequest([System.Xml.XmlElement]$nugetSource, [string]$packagePath)
{
    $url = $nugetSource.Url.Trim()

    if (![string]::IsNullOrWhiteSpace($packagePath))
    {
        $url = ($url.Trim("/"), $packagePath.Trim("/") -join "/")
    }

    $webRequest = [system.Net.WebRequest]::Create($url)
    $webRequest.set_Timeout(30000) #30 second timeout

    if (![string]::IsNullOrWhiteSpace($nugetSource.Credentials.Username))
    {
        $username = $nugetSource.Credentials.Username.Trim()
        $password = $nugetSource.Credentials.Password.Trim()

        $pair = "$($username):$($password)"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
        $base64 = [System.Convert]::ToBase64String($bytes)
        $basicAuthValue = "Basic $base64"
        $webRequest.PreAuthenticate = $true
        $webRequest.ServicePoint.Expect100Continue = $false
        $webRequest.Headers.Add("AUTHORIZATION", $basicAuthValue);
    }

    return $webRequest
}

function Confirm-NuGetSourceUrl([System.Xml.XmlElement]$nugetSource)
{
    $url = $nugetSource.Url.Trim()
    Write-Host "validating connectivity for $url" -ForegroundColor Gray

    [System.Net.WebRequest]$request = Get-WebRequest $nugetSource

    try
    {
        $response = $request.GetResponse()
    }
    catch [System.Net.WebException]
    {
        $response = $_.Exception.Response
    }

    $statusCode = [int]$response.StatusCode
    $status = $response.StatusCode
    $response.Dispose()

    if ($statusCode -ge 400)
    {
        Write-Host "There was a problem connecting to NuGet source [$url] with status: $statusCode $status" -ForegroundColor Red
        return $FALSE
    }

    return $TRUE
}

function Confirm-NuGetSources([xml]$config)
{
    $sources = $config.InstallSettings.NuGetSources.Source

    if ($sources.Count -eq 0)
    {
        Write-Host "At least one NuGet source must be specified" -ForegroundColor Red
        return $FALSE
    }

    foreach ($source in $sources)
    {
        if ([string]::IsNullOrWhiteSpace($source.Url))
        {
            Write-Host "Every NuGet source must have a url." -ForegroundColor Red
            return $FALSE
        }
        
        $url = $source.Url.Trim()
        $usernameExists = ![string]::IsNullOrWhiteSpace($source.Credentials.Username)
        $passwordExists = ![string]::IsNullOrWhiteSpace($source.Credentials.Password)

        if ($usernameExists -and !$passwordExists)
        {
            Write-Host "NuGet source [$url] missing password" -ForegroundColor Red
            return $FALSE
        }

        if (!$usernameExists -and $passwordExists)
        {
            Write-Host "NuGet source [$url] missing username" -ForegroundColor Red
            return $FALSE
        }

        if (!(Confirm-NuGetSourceUrl $source))
        {
            return $FALSE
        }
    }
    
    return $TRUE
}

function Confirm-ConfigurationSettings([xml]$config)
{
    if ([string]::IsNullOrWhiteSpace($config.InstallSettings.NuGetSources))
    {
        Write-Host "NuGetSources cannot be null or empty" -ForegroundColor Red
        return $FALSE
    }

    if ([string]::IsNullOrWhiteSpace($config.InstallSettings.'Sitecore.Ship'.PackageId))
    {
        Write-Host "PackageId cannot be null or empty" -ForegroundColor Red
        return $FALSE
    }

    if ([string]::IsNullOrWhiteSpace($config.InstallSettings.'Sitecore.Ship'.PackageVersion))
    {
        Write-Host "PackageVersion cannot be null or empty" -ForegroundColor Red
        return $FALSE
    }

    if ([string]::IsNullOrWhiteSpace($config.InstallSettings.SitecoreInstanceRoot))
    {
        Write-Host "SitecoreInstanceRoot cannot be null or empty" -ForegroundColor Red
        return $FALSE
    }

    if (!(Confirm-NuGetSources $config))
    {
        Write-Host "There was a problem with NuGetSources." -ForegroundColor Red
        return $FALSE
    }

    return $TRUE
}

function Push-ItemToList([System.Collections.Generic.List[string]]$list, [string]$item)
{
    $list.Reverse()
    $list.Add($item)   
    $list.Reverse()
    return $list
}

function Convert-RawVersion([string]$rawVersion)
{
    $arr = $rawVersion.Split("{.}")
    while ($arr.Count -lt 3)
    {
        $rawVersion += ".0"
        $arr = $rawVersion.Split("{.}")
    } 

    return $arr
}

function Get-HighestVersionNumber([string[]]$versions, [string]$rawCandidate)
{
    if ([string]::IsNullOrWhiteSpace($rawCandidate))
    {
        $rawCandidate = $versions[0]
    }

    foreach ($rawVersion in $versions)
    {
        $candidate = Convert-RawVersion $rawCandidate
        $version = Convert-RawVersion $rawVersion

        if ([int]::Parse($version[0]) -gt [int]::Parse($candidate[0]))
        {
            $rawCandidate = $rawVersion
        }
        elseif ([int]::Parse($version[0]) -eq [int]::Parse($candidate[0]))
        {
            if ([int]::Parse($version[1]) -gt [int]::Parse($candidate[1]))
            {
                $rawCandidate = $rawVersion
            }
            elseif ([int]::Parse($version[1]) -eq [int]::Parse($candidate[1]))
            {
                if ([int]::Parse($version[2]) -gt [int]::Parse($candidate[2]))
                {
                    $rawCandidate = $rawVersion
                }
            }
        }
    }

    return $rawCandidate
}

function Download-NuGetPackage([xml]$config, [string]$packageId, [string]$packageVersion, [System.Collections.Generic.List[string]]$downloadedPackages, [bool]$getExactVersion)
{
    $sources = $config.InstallSettings.NuGetSources.Source

    $candidateVersion = $packageVersion
    if (!$getExactVersion)
    {
        # Get highest version from source
        foreach ($source in $sources)
        {
            $url = $source.Url.Trim()
            $packagePath = "/package-versions/" + $packageId
            try
            {
                [System.Net.WebRequest]$request = Get-WebRequest $source $packagePath
                $request.Method = "GET"  
                $request.ContentType = "application/json"

                $responseStream = $request.GetResponse().GetResponseStream()
                $readStream = New-Object System.IO.StreamReader $responseStream
                $data = $readStream.ReadToEnd()
                $readStream.Dispose();
                $readStream.Close();
 
                # The loading of this dll assumes that even though you are on PowerShell 2.0 you have .NET 3.5 installed
                [System.Reflection.Assembly]::LoadWithPartialName("System.Web.Extensions") | Out-Null
                $serialization = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                $results = $serialization.DeserializeObject($data)
                $candidateVersion = Get-HighestVersionNumber $results $candidateVersion
            }
            catch {}
        }
        $packageVersion = $candidateVersion
    }

    $packageName = ($packageId, $packageVersion, "nupkg" -join ".")
    $targetFile = Join-Path $workingDir -ChildPath $packageName

    Write-Message $config "Attempting to download $packageName" "White"

    $isFirstAttempt = $TRUE
    foreach ($source in $sources)
    {
        if (!$isFirstAttempt)
        {
            Write-Message $config "Trying next source..." "White"
        }
        $isFirstAttempt = $FALSE

        $url = $source.Url.Trim()
        $packagePath = "/Package/" + $packageId + "/" + $packageVersion

        try
        {
            [System.Net.WebRequest]$request = Get-WebRequest $source $packagePath        
            $response = $request.GetResponse()
            $totalLength = [System.Math]::Floor($response.get_ContentLength()/1024)
            $responseStream = $response.GetResponseStream()
            $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $targetFile, Create
            $buffer = New-Object byte[] 10KB
            $count = $responseStream.Read($buffer,0,$buffer.length)
            $downloadedBytes = $count

            while ($count -gt 0)
            {
                $targetStream.Write($buffer, 0, $count)
                $count = $responseStream.Read($buffer,0,$buffer.length)
                $downloadedBytes = $downloadedBytes + $count
                Write-Progress -activity "Downloading file '$packageName'" -status "Downloaded ($([System.Math]::Floor($downloadedBytes/1024))K of $($totalLength)K): " -PercentComplete ((([System.Math]::Floor($downloadedBytes/1024)) / $totalLength)  * 100)
            }

            Write-Progress -activity "Finished downloading file '$packageName'"
            $targetStream.Flush()
            $targetStream.Close()
            $targetStream.Dispose()
            $responseStream.Dispose()
            $response.Dispose()

            $downloadedPackages = Push-ItemToList $downloadedPackages $targetFile
            $package = $downloadedPackages[0]
            Write-Message $config "Downloaded complete!" "White"

            break
        }
        catch [System.Net.WebException]
        {
            $response = $_.Exception.Response
            $statusCode = [int]$response.StatusCode
            $status = $response.StatusCode
            $message = "Couldn't download $packageName from $url [status: $statusCode $status]."
            Write-Message $config $message "Yellow"
        }
    }

    return $downloadedPackages
}

function Get-SitecoreShip([xml]$config)
{
    Write-Message $config "`nDownloading Sitecore.Ship..." "Green"

    # Ensure working directory exists
    if (!(Test-Path $workingDir))
    {
        New-Item $workingDir -type directory -force | Out-Null
    }
    
    $downloadedPackages = New-Object 'System.Collections.Generic.List[string]'
    $initialCount = $downloadedPackages.Count

    $packageId = $config.InstallSettings.'Sitecore.Ship'.PackageId.Trim()
    $packageVersion = $config.InstallSettings.'Sitecore.Ship'.PackageVersion.Trim()
    $downloadedPackages = Download-NuGetPackage $config $packageId $packageVersion $downloadedPackages $TRUE

    if ($initialCount -eq $downloadedPackages.Count)
    {
        throw "Download failed."
    }

    return $downloadedPackages
}

function Copy-NuGetPackageFiles([string]$packagePath)
{
    $unzipPath = Join-Path ([System.IO.Path]::GetDirectoryName($packagePath)) ([System.IO.Path]::GetFileNameWithoutExtension($packagePath))
    $zipPath = $unzipPath + ".zip"

    if (!(Test-Path $unzipPath))
    {
        New-Item $unzipPath -type directory -force | Out-Null
    }

    Copy-Item $packagePath $zipPath

    $shell = New-Object -com shell.application
    $zip = $shell.NameSpace($zipPath)
    foreach($item in $zip.items())
    {
        $shell.Namespace($unzipPath).copyhere($item)
    }

    Remove-Item $zipPath

    return $unzipPath
}

function Get-NuspecFileName([string]$folderPath)
{
    $dir = Get-ChildItem $folderPath -recurse 
    $list = $dir | where {$_.extension -eq ".nuspec"} 
    return $list[0].Name
}

function Read-NuGetDependencies([string]$folderPath)
{
    $nuspecPath = Join-Path $folderPath -ChildPath (Get-NuspecFileName $folderPath)
    [xml]$nuspec = Get-Content $nuspecPath

    $packagesToDownload = @{}
    $dependencies = $nuspec.package.metadata.dependencies.dependency
    foreach ($dependency in $dependencies)
    {
        $packagesToDownload.Add($dependency.id, $dependency.version)
    }
    
    return $packagesToDownload
}

function Get-DependentPackages([xml]$config, [string]$packagePath, [System.Collections.Generic.List[string]]$downloadedPackages)
{
    Write-Message $config "`nDownloading Dependent Package..." "Green"

    $extractedPackage = Copy-NuGetPackageFiles $packagePath

    $packagesToDownload = Read-NuGetDependencies $extractedPackage

    foreach ($pkg in $packagesToDownload.GetEnumerator())
    {
        $matchExactVersion = (Get-ConfigOption $config "MatchExactVersionOfDependentPackages")

        $count = $downloadedPackages.Count
        $downloadedPackages = Download-NuGetPackage $config $pkg.Name $pkg.Value $downloadedPackages $matchExactVersion

        if ($count -eq $downloadedPackages.Count)
        {
            throw "Download failed."
        }

        $downloadedPackages = Get-DependentPackages $config $downloadedPackages[0] $downloadedPackages
    }

    return $downloadedPackages
}

function Get-TransformPackage([xml]$config, [System.Collections.Generic.List[string]]$downloadedPackages)
{
    $initialCount = $downloadedPackages.Count

    $packageId = "Microsoft.Web.Xdt"
    $packageVersion = "2.1.1"    
    $downloadedPackages = Download-NuGetPackage $config $packageId $packageVersion $downloadedPackages $FALSE

    if ($initialCount -eq $downloadedPackages.Count)
    {
        throw "Download failed."
    }

    return $downloadedPackages   
}

function Copy-NuGetPackageAssemblies([xml]$config, [string]$packagePath)
{
    $folderPath = Join-Path ([System.IO.Path]::GetDirectoryName($packagePath)) ([System.IO.Path]::GetFileNameWithoutExtension($packagePath))
    $folderPath = Join-Path $folderPath -ChildPath "lib\net40"

    $installPath = $config.InstallSettings.SitecoreInstanceRoot.Trim()
    $installPath = Join-Path $installPath -ChildPath "bin"

    Get-ChildItem $folderPath -Filter *.dll | `
    Foreach-Object{
        $content = $_.FullName
        Write-Message $config "Copying $($_.Name) to \bin folder" "White"
        Copy-Item $content $installPath
    }
}

function Copy-ShipConfig([xml]$config, [string]$packagePath)
{
    $configPath = Join-Path ([System.IO.Path]::GetDirectoryName($packagePath)) ([System.IO.Path]::GetFileNameWithoutExtension($packagePath))
    $configPath = Join-Path $configPath -ChildPath "content\App_Config\Include\ship.config"

    $installPath = $config.InstallSettings.SitecoreInstanceRoot.Trim()
    $installPath = Join-Path $installPath -ChildPath "App_Config\Include"

    Write-Message $config "Copying ship.config to \App_Config\Include" "White"
    Copy-Item $configPath $installPath
}

function New-ConfigTransform([xml]$config, [string]$sourceConfigPath, [string]$transformPath)
{
    # Read the web.config.transform xml so we can modify it to use xdt directives
    [System.Xml.XmlDocument]$xml = Get-Content ($sourceConfigPath)
    $xdt = "http://schemas.microsoft.com/XML-Document-Transform"
    
    # Set namespace on <configuration> element
    $xml.configuration.SetAttribute("xmlns:xdt", $xdt)

    # <configSection>
    $sections = $xml.configuration.configSections.section
    foreach ($section in $sections)
    {
        $section.SetAttribute("Transform", $xdt, "InsertIfMissing") | Out-Null
        $section.SetAttribute("Locator", $xdt, "Match(name)") | Out-Null
    }

    # <packageInstallation>
    $xml.configuration.packageInstallation.SetAttribute("Transform", $xdt, "Insert") | Out-Null

    # IP Whitelist
    $ips = $config.InstallSettings.'Sitecore.Ship'.Options.IPWhitelist.IP
    if ($ips.Count -gt 0)
    {
        [System.Xml.XmlElement]$whitelist = $xml.CreateElement("Whitelist")
        foreach ($ip in $ips)
        {
            $elem = $xml.CreateElement("add")
            $elem.SetAttribute("name", $ip.name) | Out-Null
            $elem.SetAttribute("IP", $ip.InnerText.Trim()) | Out-Null
            $elem.SetAttribute("Transform", $xdt, "InsertIfMissing") | Out-Null
            $elem.SetAttribute("Locator", $xdt, "Match(name,IP)") | Out-Null
            $whitelist.AppendChild($elem) | Out-Null
        }            
        $xml.configuration.packageInstallation.AppendChild($whitelist) | Out-Null
    }


    [System.Xml.XmlElement]$elem = $xml.CreateElement("packageInstallation")
    $elem.SetAttribute("Transform", $xdt, "Remove") | Out-Null
    $elem.SetAttribute("Locator", $xdt, "XPath(/configuration/packageInstallation[2])") | Out-Null
    $xml.configuration.InsertAfter($elem, $xml.configuration.packageInstallation) | Out-Null
    $enabledOption = (Get-ConfigOption $config "Sitecore.Ship/Options/Enabled").ToString().ToLower()
    $xml.configuration.packageInstallation.SetAttribute("enabled", $enabledOption) | Out-Null
    $allowRemoteOption = (Get-ConfigOption $config "Sitecore.Ship/Options/AllowRemote").ToString().ToLower()
    $xml.configuration.packageInstallation.SetAttribute("allowRemote", $allowRemoteOption) | Out-Null
    $allowPackageStreamingOption = (Get-ConfigOption $config "Sitecore.Ship/Options/AllowPackageStreaming").ToString().ToLower()
    $xml.configuration.packageInstallation.SetAttribute("allowPackageStreaming", $allowPackageStreamingOption) | Out-Null
    $recordInstallationHistoryOption = (Get-ConfigOption $config "Sitecore.Ship/Options/RecordInstallationHistory").ToString().ToLower()
    $xml.configuration.packageInstallation.SetAttribute("recordInstallationHistory", $recordInstallationHistoryOption) | Out-Null
    $muteAuthorisationFailureLoggingOption = (Get-ConfigOption $config "Sitecore.Ship/Options/MuteAuthorisationFailureLogging").ToString().ToLower()
    $xml.configuration.packageInstallation.SetAttribute("muteAuthorisationFailureLogging", $muteAuthorisationFailureLoggingOption) | Out-Null




    # <nancyFx>
    $xml.configuration.nancyFx.SetAttribute("Transform", $xdt, "Insert") | Out-Null
    $elem = $xml.CreateElement("nancyFx")
    $elem.SetAttribute("Transform", $xdt, "Remove") | Out-Null
    $elem.SetAttribute("Locator", $xdt, "XPath(/configuration/nancyFx[2])") | Out-Null
    $xml.configuration.InsertAfter($elem, $xml.configuration.nancyFx) | Out-Null

    # <system.web>
    $xml.configuration.'system.web'.httpHandlers.add.SetAttribute("Transform", $xdt, "InsertIfMissing") | Out-Null
    $xml.configuration.'system.web'.httpHandlers.add.SetAttribute("Locator", $xdt, "Match(type,path)") | Out-Null

    # <system.webServer>
    $xml.configuration.'system.webServer'.modules.SetAttribute("Transform", $xdt, "SetAttributes(runAllManagedModulesForAllRequests)") | Out-Null
    $xml.configuration.'system.webServer'.validation.SetAttribute("Transform", $xdt, "SetAttributes(validateIntegratedModeConfiguration)") | Out-Null
    $xml.configuration.'system.webServer'.handlers.remove.SetAttribute("Transform", $xdt, "InsertIfMissing") | Out-Null
    $xml.configuration.'system.webServer'.handlers.remove.SetAttribute("Locator", $xdt, "Match(name)") | Out-Null
    $xml.configuration.'system.webServer'.handlers.add.SetAttribute("Transform", $xdt, "InsertIfMissing") | Out-Null
    $xml.configuration.'system.webServer'.handlers.add.SetAttribute("Locator", $xdt, "Match(name,type,path)") | Out-Null

    # <runtime>
    $runtimeXml = [xml] @"
    <runtime>
        <assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1">
            <dependentAssembly foo="bar" />
            <dependentAssembly>
                <assemblyIdentity name="Antlr3.Runtime" publicKeyToken="eb42632606e9261f" />
                <bindingRedirect oldVersion="0.0.0.0-3.5.0.0" newVersion="3.5.0.2" />
            </dependentAssembly>
        </assemblyBinding>
    </runtime>
"@
    $xml.configuration.AppendChild($xml.ImportNode(($runtimeXml.runtime), $true)) | Out-Null
    $xml.configuration.runtime.assemblyBinding.dependentAssembly[0].SetAttribute("Transform", $xdt, "Remove") | Out-Null
    $xml.configuration.runtime.assemblyBinding.dependentAssembly[0].SetAttribute("Locator", $xdt, "Condition(./_defaultNamespace:assemblyIdentity/@name='Antlr3.Runtime')") | Out-Null
    $xml.configuration.runtime.assemblyBinding.dependentAssembly[0].RemoveAttribute("foo")
    $xml.configuration.runtime.assemblyBinding.dependentAssembly[1].SetAttribute("Transform", $xdt, "Insert") | Out-Null

    # Save changes
    $xml.Save($transformPath);
}

function Write-WebConfig([xml]$config, [string]$packagePath, [string]$transformPackagePath)
{
    $packageFolder = Join-Path ([System.IO.Path]::GetDirectoryName($packagePath)) ([System.IO.Path]::GetFileNameWithoutExtension($packagePath))
    $tranformPackageFolder = Join-Path ([System.IO.Path]::GetDirectoryName($transformPackagePath)) ([System.IO.Path]::GetFileNameWithoutExtension($transformPackagePath))
    $configPath = Join-Path $packageFolder -ChildPath "content\web.config.transform"
    $configTransformPath = Join-Path $packageFolder -ChildPath "content\web.config.release"
    $webConfigFile = Join-Path ($config.InstallSettings.SitecoreInstanceRoot.Trim()) -ChildPath "web.config"

    # Create a web.config transform from the config in the NuGet package
    New-ConfigTransform $config $configPath $configTransformPath

    $xdtDll = (Get-ChildItem -Path $tranformPackageFolder -Include 'Microsoft.Web.XmlTransform.dll' -Recurse) | Select-Object -First 1
    $dllPath = Join-Path $scriptDir -ChildPath ($xdtDll.Name)
    if (!(Test-Path $dllPath))
    {
        Copy-Item $xdtDll.FullName $scriptDir
    }
    [System.Reflection.Assembly]::LoadFile($dllPath) | Out-Null

    $xmldoc = New-Object Microsoft.Web.XmlTransform.XmlTransformableDocument;
    $xmldoc.PreserveWhitespace = $true
    $xmldoc.Load($webConfigFile);

    $transf = New-Object Microsoft.Web.XmlTransform.XmlTransformation($configTransformPath);
    if ($transf.Apply($xmldoc) -eq $false)
    {
        throw "Transformation failed."
    }

    Write-Message $config "Modifying web.config" "White"
    $xmldoc.Save($webConfigFile);
}

function Install-SitecoreShipNuGetPackage([xml]$config, [string]$packagePath, [string]$transformPackage)
{
    Copy-NuGetPackageAssemblies $config $packagePath

    Copy-ShipConfig $config $packagePath

    Write-WebConfig $config $packagePath $transformPackage
}

function Install-AllNuGetPackages([xml]$config, [System.Collections.Generic.List[string]]$downloadedPackages)
{
    Write-Message $config "`nInstalling packages to Sitecore..." "Green"

    $transformPackage = $downloadedPackages[0]
    $downloadedPackages.RemoveAt(0)
    Copy-NuGetPackageFiles $transformPackage | Out-Null

    foreach ($package in $downloadedPackages)
    {
        $filename = [System.IO.Path]::GetFileNameWithoutExtension($package)
        if ($filename.StartsWith("Sitecore.Ship"))
        {
            Install-SitecoreShipNuGetPackage $config $package $transformPackage
        }
        else
        {
            Copy-NuGetPackageAssemblies $config $package
        }
    }
    
    Write-Message $config "Installation complete!" "White"
}

function Install-SitecoreShip([string]$configPath)
{
    [xml]$config = Read-InstallConfigFile $configPath
    if ($config -eq $null)
    {
        Write-Host "Aborting install." -ForegroundColor Red
        return
    }
    
    $stopWatch = [Diagnostics.Stopwatch]::StartNew()
    $date = Get-Date

    $configIsValid = Confirm-ConfigurationSettings $config
    if (!$configIsValid)
    {
        Write-Message $config "Aborting install: SitecoreShipInstall.xml file has a bad setting." "Red"
        return
    }

    $message = "`nStarting install of Sitecore.Ship - $date" 
    Write-Message $config $message "Green"

    try
    {
        [System.Collections.Generic.List[string]]$downloadedPackages = Get-SitecoreShip $config

        $downloadedPackages = Get-DependentPackages $config $downloadedPackages[0] $downloadedPackages

        $downloadedPackages = Get-TransformPackage $config $downloadedPackages

        Install-AllNuGetPackages $config $downloadedPackages
    }
    catch [Exception]
    {
        Write-Message $config  ($_.Exception.Message) "Red"
        Write-Message $config "Aborting install. Check your NuGet sources and config file and try again." "Red"
        return
    }
    finally
    {
        if (Get-ConfigOption $config "CleanTempFilesWhenDone")
        {
            Remove-Item $workingDir -Recurse
        }
        
        $stopWatch.Stop()
        $message = "`nSitecore.Ship install finished - Elapsed time {0}.{1} seconds" -f $stopWatch.Elapsed.Seconds, $stopWatch.Elapsed.Milliseconds
        Write-Message $config $message "Green"
    }
}

Install-SitecoreShip $configPath
