# This script will create a WiFi profile and connect to the specified WiFi networking
# Set the profile name, SSID, and password based on Custom fields 'wifiSsid' and 'wifiPassword' in NinjaOne
# Written by Brian Cook - Unified Technology Solutions with help from MatDew & Mikey (homotechsual)

# Set the profile name, SSID, and password
$profileName = Ninja-Property-Get wifiSsid
$ssid = Ninja-Property-Get wifiSsid
$password = Ninja-Property-Get wifiPassword
$authentication = Ninja-Property-Get wifiAuthenticationType

#Check if either field is blank and exit
if ([String]::IsNullOrWhiteSpace($ssid))
{
	Write-Host "ERROR: WiFi network SSID blank" 
	exit 1
}
if ([String]::IsNullOrWhiteSpace($password))
{
	Write-Host "ERROR: WiFi network password blank."
	exit 1
}
if ([String]::IsNullOrWhiteSpace($authentication))
{
	Write-Host "ERROR: WiFi network Authentication Type blank."
	exit 1
}

#Escape vslues in case they contain XML special characters
$escapedSsid = [System.Security.SecurityElement]::Escape($ssid)
$escapedPassword = [System.Security.SecurityElement]::Escape($password)
$escapedProfileName = [System.Security.SecurityElement]::Escape($profileName)


# For Testing
# Write-Host "WiFi network name read as '$ssid' with password '$password'."


# Create a new WiFi profile
$wifiProfileXml = @"
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
	<name>$escapedProfileName</name>
	<SSIDConfig>
		<SSID>
			<name>$escapedSsid</name>
		</SSID>
	</SSIDConfig>
	<connectionType>ESS</connectionType>
	<connectionMode>auto</connectionMode>
	<MSM>
		<security>
			<authEncryption>
				<authentication>$authentication</authentication>
				<encryption>AES</encryption>
				<useOneX>false</useOneX>
			</authEncryption>
			<sharedKey>
				<keyType>passPhrase</keyType>
				<protected>false</protected>
				<keyMaterial>$escapedPassword</keyMaterial>
			</sharedKey>
		</security>
	</MSM>
</WLANProfile>
"@

# Use UTF-8 to avoid netsh error
[System.IO.File]::WriteAllText($profilePath, $wifiProfileXml, [System.Text.Encoding]::UTF8)

# Add the WiFi profile
$profilePath = [System.IO.Path]::Combine($env:TEMP, "$profileName.xml")
Set-Content -Path $profilePath -Value $wifiProfileXml
netsh wlan add profile filename=$profilePath

# Connect to the WiFi network using the created profile
netsh wlan connect name=$ssid

Write-Host "WiFi network '$ssid' set up successfully."