# Modules

PowerShell modules carried on the USB. Tech Kit puts this folder first in
`PSModulePath`, so anything here is used before what is installed on the PC.

Fill it with the **Update USB Modules** script in the Tech Kit category (downloads everything listed in
`Config\modules.json`), or answer "Download to USB" when Tech Kit says a module
is missing. This folder is ignored by git because the modules are large.
