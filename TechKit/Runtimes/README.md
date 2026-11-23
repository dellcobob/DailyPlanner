# Runtimes

Optional portable interpreters. Nothing here is required.

| Folder | What to put in it | Used for |
|---|---|---|
| `pwsh\` | Extract the PowerShell 7 **zip** (win-x64) here so `pwsh\pwsh.exe` exists. The **Put PowerShell 7 on the USB** script (Tech Kit category) does this for you. | Runs Tech Kit on PowerShell 7 on PCs that only have 5.1 |
| `python\` | The Python "embeddable package" zip for Windows, extracted so `python\python.exe` exists | Running `.py` scripts on PCs without Python |
| `git\` | PortableGit, extracted so `git\bin\bash.exe` exists | Running `.sh` scripts on PCs without Git Bash or WSL |
