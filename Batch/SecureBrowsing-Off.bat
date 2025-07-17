rem - Turns off Secure Browsing on common browsersso filtering will work.
rem - Written by Brian Cook - Unified Technology Solutions

rem - Brave Browser
REG ADD HKLM\SOFTWARE\Policies\BraveSoftware\Brave /v IPFSEnabled /t REG_DWORD /d 0 /f
REG ADD HKLM\SOFTWARE\Policies\BraveSoftware\Brave /v TorDisabled /t REG_DWORD /d 1 /f

rem - Chrome Browser
REG ADD HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome /v DnsOverHttpsMode /t REG_SZ /d off /f

rem - Edge Chromium Browser
REG ADD HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge /v DnsOverHttpsMode /t REG_SZ /d off /f

rem - Firefox Browser
REG ADD HKEY_LOCAL_MACHINE\Software\Policies\Mozilla\Firefox\DNSOverHTTPS /v Enabled /t REG_DWORD /d 00000000 /f
REG ADD HKEY_LOCAL_MACHINE\Software\Policies\Mozilla\Firefox\DNSOverHTTPS /v Locked /t REG_DWORD /d 00000001 /f