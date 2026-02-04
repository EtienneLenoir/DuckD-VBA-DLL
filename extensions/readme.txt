# DuckDB Extensions — Manual Install (Corporate / Offline Environments)

In some corporate environments (proxy, locked-down endpoints, no internet access, restricted user permissions),
DuckDB may fail to download extensions automatically using `INSTALL <ext>;`.

This guide explains how to **manually install** DuckDB extensions by placing the extension files in DuckDB’s
local extension cache folder.

## Where DuckDB stores extensions (Windows)

DuckDB caches extensions per version and platform in the user profile directory:

**Default path:**
C:\Users<USERNAME>.duckdb\extensions\v1.4.3\windows_amd64\

Replace:
- `<USERNAME>` with the current Windows user
- `v1.4.3` with **your DuckDB version**
- `windows_amd64` is the typical folder for Windows 64-bit

> Example (generic):
> `C:\Users\john.doe\.duckdb\extensions\v1.4.3\windows_amd64\`


## Manual installation steps

1) **Download the extension package** (ZIP or the `.duckdb_extension` file) from an approved source  
   (e.g., internal mirror, IT-provided package, or an offline bundle).

2) **Unzip** the package (if provided as a ZIP).

3) Copy the extension file(s) into the DuckDB extension cache directory:

