# Libraries

Extra script collections, each in its own folder (for example `Libraries\AdminDroid`).
Every folder shows up in Tech Kit as its own category, marked LIB.

- Download one with **Add Script Library from GitHub** (Tech Kit category), or copy a
  folder of `.ps1` files here and click **Reload library**.
- Scripts do not need a Tech Kit header. Tech Kit reads the name and description from
  their opening comment, builds the input form from `param()`, and guesses the
  "makes changes" and "Microsoft 365" flags from the code.
- When a library script calls `Connect-MgGraph` or `Connect-ExchangeOnline`, Tech Kit
  reuses the connection you already made with the Microsoft 365 button.
- This folder is ignored by git: libraries are other people's code and keep their own
  licenses. Review a library before running it on a client network.
