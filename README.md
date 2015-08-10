Sitecore.Ship-PowerShell-Installer
====================================
This PowerShell script will install Sitecore.Ship onto a Sitecore instance from a NuGet package. Here is an overview of the steps performed:

1. Download Sitecore.Ship from a NuGet feed
2. Recursively download dependent packages
3. Create a web.config transform from Sitecore.Ship's NuGet packages and your chosen options
4. Install assemblies and apply config files
5. Writes to an (optional) log file 

### Requirements
- Target Sitecore instance must be Sitecore 8 initial release or greater
- Sitecore.Ship NuGet Package must be 0.4.0+
- Identity of account running script must have read/write access to Sitecore web site file system.

### How To Use
1. Download script and config file
2. Edit config file
3. Run Powershell as Administrator and invoke ```.\SitecoreShipInstall.ps1```

NOTE: I've included a development branch build of the .nupkg file from Sitecore.Ship for your convenience. This is the package I have tested my script against. Once this package is available on a public feed, I will remove it.

### Troubleshooting
- If you see an error in PowerShell complaining that "the execution of scripts is disabled on this system." then you need to invoke ```Set-ExecutionPolicy -ExecutionPolicy unrestricted -Force```
- If you receive a security warning after invoking ```.\SitecoreShipInstall.ps1``` and want to make it go away permanently, then right-click on the install.ps1 file and "Unblock" it.
