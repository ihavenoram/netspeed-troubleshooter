# Quick start

Pick the way you're reaching the machine. Each path is a handful of steps, and none of them needs an installer.

- [A. You're on the machine, or in a remote session](#a-youre-on-the-machine-or-in-a-remote-session)
- [B. ScreenConnect Backstage (or any SYSTEM shell)](#b-screenconnect-backstage-or-any-system-shell)
- [C. Turn a saved report into a page](#c-turn-a-saved-report-into-a-page)
- [D. Was it the backup internet connection?](#d-was-it-the-backup-internet-connection)
- [Reading the result](#reading-the-result)

---

## A. You're on the machine, or in a remote session

1. Download `NetSpeed-Troubleshooter.zip` from [Releases](../../releases/latest) and extract it anywhere on a local disk.
2. Double-click **`Launch-NetSpeed-Troubleshooter.cmd`**.
3. Check the **Link** line at the top. Red there (a wired adapter below 100 Mbps, or half duplex) is your answer before you test anything: swap the patch lead and switch port first.
4. If you know the customer's plan, type it into **Stated plan** (down / up, in Mbps). Leave it at 0 if you don't; the tool won't grade against a plan you didn't give it.
5. Press **Quick Sweep** and wait about a minute.
6. Read the **Overview** tab: the overall result is the worst measured line, and each line says what to do about it.
7. Press **Save Report...** to keep the JSON for the ticket.

Optional, from the tabs:

- **Bandwidth Hogs → ETW Deep Capture (20s)** for real per-process bytes. Needs admin.
- **Throughput → Ookla (authoritative)** when the ISP wants a speedtest.net Result URL. It asks first, because it downloads the Ookla CLI (about 1 MB) and can use a few hundred MB of data on a fast link.
- **Live Monitor → Start Monitor**, then get the user to reproduce the slowness.
- **Soak / Intermittent** for "it only drops out sometimes". 15 minutes is the minimum it will draw a conclusion from.

## B. ScreenConnect Backstage (or any SYSTEM shell)

1. In Backstage, open the file transfer and **drag the extracted `NetSpeed-Troubleshooter` folder to `C:\temp`**. Keep the files together: the GUI loads its helpers from beside itself.
2. In the Backstage command prompt, run:

   ```bat
   C:\temp\NetSpeed-Troubleshooter\Launch-NetSpeed-Troubleshooter.cmd
   ```

3. Everything in A works the same from here. Under SYSTEM the clipboard may be unavailable, so use **Save Report...** instead of Copy Report.

Don't add `-WindowStyle Hidden` if you start it some other way: it hides the window as well as the console. When you're done, delete the folder from `C:\temp`.

## C. Turn a saved report into a page

```powershell
powershell.exe -NoProfile -STA -File .\NetSpeed_HTML_Report.ps1
```

With no arguments it opens a small window: drop in the `.json` you saved, or paste the report text, then press **Render**. It writes one self-contained HTML file you can email to a client or an ISP. From the command line:

```powershell
powershell.exe -NoProfile -File .\NetSpeed_HTML_Report.ps1 -JsonPath ".\NetSpeed_PC01_20260101_101500.json" -NoGui
```

It only renders. It never measures anything.

## D. Was it the backup internet connection?

One run can't tell you which internet connection it measured. Record the public address every five minutes while the problem is happening.

The recorder runs as a scheduled SYSTEM task, so it must live where **only administrators can change it**. That rules out `C:\temp`, Downloads and `C:\ProgramData`, and the script refuses to install from them, because a standard user could otherwise edit what SYSTEM runs. As an administrator:

1. Copy the `NetSpeed-Troubleshooter` folder to **`C:\Program Files\NetSpeedTroubleshooter`**.
2. Install the task:

   ```powershell
   powershell.exe -NoProfile -File "C:\Program Files\NetSpeedTroubleshooter\Watch-NsEgress.ps1" -Install "true" -IntervalSec "300"
   ```

Later:

```powershell
powershell.exe -NoProfile -File "C:\Program Files\NetSpeedTroubleshooter\Watch-NsEgress.ps1" -Report "true"      # what changed, and when
powershell.exe -NoProfile -File "C:\Program Files\NetSpeedTroubleshooter\Watch-NsEgress.ps1" -Uninstall "true"   # remove the task
```

Two addresses with very different latency are two different connections; two similar ones are the same connection renumbered. With history recorded, the GUI's **Route** line becomes conclusive rather than suggestive.

## Reading the result

- **Green / amber / red** are judgements. Each comes with what to do next.
- **not measured** means it didn't run or couldn't; it never counts against the result.
- The **Basis** column says how a number was obtained. `measured` is real; `inference` is a well-founded guess; `withheld` means the tool had a number and refused to publish it because it was below the instrument's resolution.
- A clean report means **nothing on this PC** explains the slowness. Another device on the network can still be using the link; use the Live Monitor while it happens to see that.

For how every figure is measured, and why, see [docs/TECHNICAL.md](docs/TECHNICAL.md).
