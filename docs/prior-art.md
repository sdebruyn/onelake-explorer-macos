# Prior art research

Research done before starting implementation, to verify that no comparable project already exists. **Findings: the niche is empty.**

## What exists

| Project | Description | Overlap with OFEM |
|---|---|---|
| [Microsoft OneLake File Explorer](https://learn.microsoft.com/fabric/onelake/onelake-file-explorer) | Official integration with Windows File Explorer. Windows 10/11 only. | Same goal, different platform — this is the project we are porting/replacing for macOS. |
| [Azure Storage Explorer](https://azure.microsoft.com/products/storage/storage-explorer) | Microsoft's cross-platform Electron app for Azure Storage. Works on Mac with manual OneLake URL pasting. | Workaround tool, not Finder integration. No mount. No multi-account hierarchy. |
| [djouallah/onelake-explorer](https://github.com/djouallah/onelake-explorer) | 17 KB JavaScript single-page web app (4 files: `app.js`, `index.html`, `style.css`, `.nojekyll`). No README, 0 stars at time of writing. Created March 2026, hosted on GitHub Pages. | Browser-only OneLake viewer. No native macOS integration, no Finder mount, no daemon, no multi-account management. Different scope entirely. |
| [Fabric Community thread "Onelake Explorer for Mac"](https://community.fabric.microsoft.com/t5/Desktop/Onelake-Explorer-for-Mac/td-p/4152115) | Opened September 2024 by a Microsoft employee (Sparkie) asking when a Mac version is coming. Microsoft moderator answered "no specific announcements or timelines". Users have +1'd. | Validation of market demand. No competing product. |
| [sling-cli](https://github.com/slingdata-io/sling-cli), [OCI Go SDK Microsoft Fabric connector](https://github.com/oracle/oci-go-sdk), [terraform-provider-fabric](https://github.com/microsoft/terraform-provider-fabric), [OpenFoundry](https://github.com/DioCrafts/OpenFoundry) | Data-engineering tools that speak the OneLake DFS URL for ETL/pipeline use cases. | Different use case (data movement and IaC), no file browsing, no macOS integration, no mount. |

## What does NOT exist

- A native macOS app that mounts OneLake in Finder.
- Any open-source macOS client for OneLake.
- A File Provider Extension for OneLake from any party.
- A Homebrew formula or cask for OneLake tooling beyond Azure-CLI-style data tools.
- A multi-tenant / multi-account OneLake browser of any shape.

## Implications for OFEM

- The niche is empty. We are first.
- Market demand is validated by Microsoft's own community thread.
- We do not need to match-or-beat an existing competitor — our reference is the Windows file explorer behavior, with the multi-account / multi-tenant limitations explicitly improved.
- Risk: Microsoft could ship an official Mac version. Their public stance is "no announcements". If they do, OFEM either stays as an open-source / multi-account alternative or sunsets gracefully.

## How this research was done

- GitHub repo search: `onelake macos`, `onelake fuse`, `onelake explorer`, `onelake mount`, `fabric onelake mac`.
- GitHub code search: Go files containing `onelake.dfs.fabric`.
- Web search: "OneLake macOS open source", "OneLake File Explorer Mac alternative".
- Microsoft Fabric community forum review.
- Microsoft Learn search for any roadmap mention of macOS support.
