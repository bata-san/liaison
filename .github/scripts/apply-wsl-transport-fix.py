from pathlib import Path


def replace_once(path: str, old: str, new: str, marker: str) -> None:
    file = Path(path)
    text = file.read_text(encoding="utf-8-sig")
    if marker in text:
        print(f"{path}: fix already applied")
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one patch location in {path}, found {count}")
    file.write_text(text.replace(old, new, 1), encoding="utf-8", newline="\n")
    print(f"{path}: patched")


replace_once(
    "scripts/install-server-bundle.ps1",
    '            $rawOutput = & "$env:SystemRoot\\System32\\wsl.exe" -d $Distribution -u root --exec sh -lc $Script 2>&1',
    '''            # Windows PowerShell 5.1 can truncate multiline native arguments. Encode the
            # script as one ASCII argument, then restore the exact UTF-8/LF content in WSL.
            $normalizedScript = $Script.Replace("`r`n", "`n").Replace("`r", "`n")
            $encodedScript = [Convert]::ToBase64String(
                [Text.UTF8Encoding]::new($false).GetBytes($normalizedScript)
            )
            $transportCommand = "printf %s $encodedScript | base64 -d | sh"
            $rawOutput = & "$env:SystemRoot\\System32\\wsl.exe" -d $Distribution -u root --exec sh -lc $transportCommand 2>&1''',
    "$transportCommand = \"printf %s $encodedScript | base64 -d | sh\"",
)

replace_once(
    "scripts/bootstrap-dependencies.ps1",
    '    & wsl.exe -d $Distribution -u root -- sh -lc $Script',
    '''    # Keep multiline shell programs out of the Windows native command line. PowerShell
    # 5.1 may split or truncate them, especially around newlines and shell control flow.
    $normalizedScript = $Script.Replace("`r`n", "`n").Replace("`r", "`n")
    $encodedScript = [Convert]::ToBase64String(
        [Text.UTF8Encoding]::new($false).GetBytes($normalizedScript)
    )
    $transportCommand = "printf %s $encodedScript | base64 -d | sh"
    & wsl.exe -d $Distribution -u root -- sh -lc $transportCommand''',
    "Keep multiline shell programs out of the Windows native command line",
)

replace_once(
    "apps/liaison-installer/src-tauri/src/main.rs",
    '''fn summarize_failure(log: &str) -> Option<String> {
    log.lines()
        .rev()
        .map(str::trim)
        .find(|line| {
            !line.is_empty()
                && (line.contains("Installation failed:")
                    || line.contains("Setup failed:")
                    || line.contains("セットアップに失敗")
                    || line.contains("エラー"))
        })
        .map(str::to_owned)
}''',
    '''fn summarize_failure(log: &str) -> Option<String> {
    let lines: Vec<&str> = log.lines().map(str::trim).filter(|line| !line.is_empty()).collect();

    // Prefer the inner installer failure, which contains the actionable WSL/Docker
    // diagnostic. The final wrapper line usually contains only a generic exit code.
    for marker in ["Installation failed:", "セットアップに失敗", "エラー", "Setup failed:"] {
        if let Some(line) = lines.iter().rev().find(|line| line.contains(marker)) {
            return Some((*line).to_owned());
        }
    }
    None
}''',
    "Prefer the inner installer failure",
)
