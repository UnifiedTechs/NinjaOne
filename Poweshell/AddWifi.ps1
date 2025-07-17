# This script will create a WiFi profile and connect to the specified WiFi networking
# Set the profile name, SSID, and password based on Custom fields 'wifiSsid' and 'wifiPassword' in NinjaOne
$profileName = Ninja-Property-Get wifiSsid
$ssid = Ninja-Property-Get wifiSsid
$password = Ninja-Property-Get wifiPassword

# Create a new WiFi profile
$wifiProfileXml = @"
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
	<name>$profileName</name>
	<SSIDConfig>
		<SSID>
			<name>$ssid</name>
		</SSID>
	</SSIDConfig>
	<connectionType>ESS</connectionType>
	<connectionMode>auto</connectionMode>
	<MSM>
		<security>
			<authEncryption>
				<authentication>WPA2PSK</authentication>
				<encryption>AES</encryption>
				<useOneX>false</useOneX>
			</authEncryption>
			<sharedKey>
				<keyType>passPhrase</keyType>
				<protected>false</protected>
				<keyMaterial>$password</keyMaterial>
			</sharedKey>
		</security>
	</MSM>
</WLANProfile>
"@

# Add the WiFi profile
$profilePath = [System.IO.Path]::Combine($env:TEMP, "$profileName.xml")
Set-Content -Path $profilePath -Value $wifiProfileXml
netsh wlan add profile filename=$profilePath

# Connect to the WiFi network using the created profile
netsh wlan connect name=$ssid

Write-Host "WiFi network '$ssid' set up successfully with password '$password' and connected."