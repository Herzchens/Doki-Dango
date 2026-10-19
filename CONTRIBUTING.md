# Contributing to Doki-Dango

Thank you for your interest in contributing to Doki-Dango.

## Project Status

Doki-Dango is currently in an active pre-production development state. The current implementation surface centers around:
- **Windows Host & UI** (`windows/`)
- **Android Notification Harness** (`android/`)
- **Shared Canonical Contracts** (`shared/`)
- **Integration Harnesses** (`integration/`)

## Repository Ownership Structure

The repository is organized strictly by platform ownership:
- `windows/`: Windows Host authoritative background daemon, UI bootstrap scaffold, platform integrations (WinRT notification listener, DPAPI credential protection), and Windows MSIX packaging.
- `android/`: Android companion application and Firebase Cloud Messaging harness.
- `shared/`: Cross-platform canonical contracts and protocol test vectors.
- `integration/`: Multi-platform end-to-end integration tests and tracing harnesses.
- `docs/`: Architecture Decision Records (ADRs) and public technical documentation.

## Contribution Guidelines

1. **Focused Changes**: Create a focused branch targeting `main` for each feature or bugfix. Keep unrelated changes separate.
2. **Architectural Discussions**: For substantial architectural changes or shared protocol modifications, open an issue to discuss design intent prior to implementation.
3. **PR Descriptions**: Public pull request descriptions should be concise and explain **What** changed and **Why**. Avoid internal logs or execution diaries.
4. **Secret and Hygiene Boundaries**:
   - Never commit secrets, service account credentials, Firebase instance IDs (FIDs), private keys, certificates, or development tokens.
   - Do not commit built packages (`.msix`, `.apk`), build caches, or temporary local evidence logs.
   - Internal planning documents (such as `PLAN.md` or `AGENTS.md`) are not public repository artifacts and must not be committed.
5. **Testing & CI Gate**:
   - Run relevant local tests for modified areas before opening a pull request.
   - Continuous Integration uses an affected-area detection workflow. Pull requests are expected to pass the aggregate **`CI required`** status check, which evaluates all necessary platform builds and syntax validations.
