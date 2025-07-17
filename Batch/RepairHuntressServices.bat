rem Set up a condition in NinjaOne to detect if  any if these services are down and if so run this script.
rem By Brian Cook - Unified Technology Solutions

rem - set all services back to auto start if changed
sc.exe config HuntressAgent start=auto
sc.exe config HuntressUpdater start=auto
sc.exe config HuntressRio start=auto

rem - starts all services
sc.exe start HuntressAgent
sc.exe start HuntressUpdater
sc.exe start HuntressRio