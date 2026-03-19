# HestiaCP Deep Bug Scan Report

**Date:** 2026-03-19
**Scanner:** OpenClaw AI Deep Shell Scanner
**Scope:** `install/`, `func/`, `bin/`, `web/`

---

## Critical Bugs

### BUG-001: Double caret (`^^`) regex in `is_user_format_valid`
- **File:** `func/main.sh`, line 742
- **Severity:** HIGH
- **Description:** The regex `^[[:alnum:]]$` is prefixed with `^^` (double caret). The second `^` is interpreted as a literal character match, causing the regex to fail for all single-character inputs.
- **Code:** `if ! [[ "$1" =~ ^^[[:alnum:]]$ ]]; then`
- **Fix:** Remove the extra caret: `if ! [[ "$1" =~ ^[[:alnum:]]$ ]]; then`

### BUG-002: Unquoted variable in `is_package_valid` test
- **File:** `func/main.sh`, line 259
- **Severity:** HIGH
- **Description:** `[ -z $1 ]` without quotes around `$1`. If `$1` is unset or contains spaces, the test behaves incorrectly. With `set -u` or word splitting, this could produce wrong results.
- **Code:** `if [ -z $1 ]; then`
- **Fix:** `if [ -z "$1" ]; then`

### BUG-003: Unquoted variables in `mysql_connect` and `psql_connect` tests
- **File:** `func/db.sh`, lines 42-43, 138-139
- **Severity:** HIGH
- **Description:** Multiple `[ -z $PORT ]` and `[ -z $HOST ]` etc. without quotes. If variables are empty or contain spaces/globs, these tests will malfunction.
- **Code:**
  ```
  if [ -z $PORT ]; then PORT=3306; fi
  if [ -z $HOST ] || [ -z $USER ] || [ -z $PASSWORD ]; then
  ```
- **Fix:** Quote all variables: `if [ -z "$PORT" ]; then PORT=3306; fi` etc.

### BUG-004: Unquoted variables in `psql_connect` tests
- **File:** `func/db.sh`, lines 138-139
- **Severity:** HIGH
- **Description:** Same issue as BUG-003 but for PostgreSQL connections.
- **Fix:** Quote all variables in the conditionals.

### BUG-005: Unquoted error code in `check_result` calls
- **File:** `func/main.sh`, line 1679; `func/domain.sh`, lines 119, 349, 358, 722; `func/ip.sh`, lines 141, 243
- **Severity:** MEDIUM
- **Description:** `check_result $E_INVALID` without quoting `$E_INVALID`. While these are numeric constants and unlikely to cause issues, it's inconsistent with the rest of the codebase and violates best practices.
- **Fix:** Quote the error codes: `check_result "$E_INVALID"` etc.

---

## Medium Severity Bugs

### BUG-006: Unquoted variables in `rm -f` commands throughout backup.sh
- **File:** `func/backup.sh`, lines 13, 26, 34, 165, 441, 465, 554
- **Severity:** MEDIUM
- **Description:** `rm -f $BACKUP/$user.$backup_new_date.tar` without quoting the path. If `$user` or `$backup_new_date` contains spaces or glob characters, wrong files could be deleted.
- **Fix:** Quote all paths: `rm -f "$BACKUP/$user.$backup_new_date.tar"`

### BUG-007: Unquoted variables in `rm -f` commands throughout main.sh
- **File:** `func/main.sh`, line 689
- **Severity:** MEDIUM
- **Description:** `rm -f $crontab` without quoting. If the crontab path contains spaces, wrong file could be deleted.
- **Fix:** `rm -f "$crontab"`

### BUG-008: Unquoted variables in `rm -f` commands in domain.sh
- **File:** `func/domain.sh`, lines 848-872, 975-993
- **Severity:** MEDIUM
- **Description:** Multiple `rm -f` commands with unquoted variable paths containing `$user`, `$domain`, etc.
- **Fix:** Quote all file path arguments to `rm -f`.

### BUG-009: Unquoted variables in `rm -f` in db.sh
- **File:** `func/db.sh`, lines 80, 91, 163
- **Severity:** MEDIUM
- **Description:** `rm -f $mysql_out` without quoting.
- **Fix:** `rm -f "$mysql_out"`

### BUG-010: Dead code (commented `# fi`) in hst-install.sh
- **File:** `install/hst-install.sh`, lines 114, 127
- **Severity:** LOW
- **Description:** Remnants of `# fi` from removed if blocks. While not functional bugs, they indicate incomplete cleanup and could confuse maintainers.
- **Fix:** Remove the dead `# fi` comments.

### BUG-011: Unquoted `$*` in `check_wget_curl` function
- **File:** `install/hst-install.sh`, lines 108, 123
- **Severity:** MEDIUM
- **Description:** `$*` is unquoted when passed to `bash hst-install-$type.sh $*`. Arguments containing spaces will be split. Should use `"$@"` instead.
- **Fix:** Use `"$@"` instead of `$*`.

### BUG-012: Unquoted `$*` in main installer check
- **File:** `install/hst-install.sh`, line 133
- **Severity:** MEDIUM
- **Description:** `check_wget_curl $*` - same issue as above.
- **Fix:** `check_wget_curl "$@"`

---

## Low Severity / Code Quality Issues

### BUG-013: `egrep` and `fgrep` deprecation warnings
- **File:** `func/domain.sh`, lines 345, 355; `install/hst-install-debian.sh`, lines 327, 343; `install/hst-install-ubuntu.sh`, lines 328, 344
- **Severity:** LOW
- **Description:** `egrep` and `fgrep` are deprecated in modern GNU grep. They emit warnings on some systems.
- **Fix:** Replace `egrep` with `grep -E` and `fgrep` with `grep -F`.

### BUG-014: Missing `set -o pipefail` in critical scripts
- **File:** `func/main.sh`, `func/backup.sh`, `func/domain.sh`, `func/db.sh`
- **Severity:** LOW
- **Description:** None of the function library scripts use `set -o pipefail`. In pipelines like `cmd1 | cmd2`, only the exit status of `cmd2` is checked. Failed `cmd1` commands are silently ignored.
- **Fix:** Add `set -o pipefail` to function libraries (note: this is a design decision that could affect existing behavior).

### BUG-015: Typo "extention" (should be "extension")
- **File:** `func/main.sh`, function name `is_extention_format_valid` and its error messages
- **Severity:** LOW
- **Description:** "extention" is misspelled; should be "extension". This is used in function names and error messages.
- **Fix:** Rename function and fix error messages (note: renaming the function requires updating all callers).

### BUG-016: Typos in variable name "maxlenght" (should be "maxlength")
- **File:** `func/main.sh`, lines ~695, ~710, ~725
- **Severity:** LOW
- **Description:** Variable `maxlenght` is misspelled; should be `maxlength`.
- **Fix:** Rename variable consistently (note: purely internal, no functional impact).

---

## Summary

| Severity | Count |
|----------|-------|
| HIGH     | 5     |
| MEDIUM   | 7     |
| LOW      | 4     |
| **Total** | **16** |

## Recommendations

1. **Immediate fixes needed:** BUG-001 through BUG-005 should be fixed as they can cause runtime errors.
2. **Code hygiene:** BUG-006 through BUG-012 should be fixed to prevent word-splitting issues.
3. **Best practices:** Consider adding `set -o pipefail` and standardizing variable quoting across the codebase.
