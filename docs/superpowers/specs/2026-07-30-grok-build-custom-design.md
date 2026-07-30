# Design Spec: `grok-build` Customization & Architecture Strategy

**Date:** 2026-07-30  
**Target Repository:** `grok-build` (Rust Workspace)  
**Branch:** `custom-main`  

---

## 1. Executive Summary

This document specifies the branching strategy and modular software architecture for customizing **`grok-build`** (xAI's terminal-based AI coding agent). The key architectural constraint is ensuring that custom features (built-in tools, model proxies, system prompts, and UI adjustments) are completely decoupled from upstream code, allowing smooth periodic synchronization with `upstream/main` with minimal Git merge conflicts.

---

## 2. Git Branch & Workflow Strategy

### 2.1 Branch Definitions
- **`main`**: Pristine branch tracking `upstream/main`. **Zero custom code changes allowed.**
- **`custom-main`**: Active development branch. Contains the custom extension crate (`xai-grok-custom`) and minimal initialization hook points.

### 2.2 Upstream Synchronization Workflow
When new releases or updates are published to the original `grok-build` repository:
```bash
git checkout main
git fetch upstream
git merge upstream/main
git push origin main

git checkout custom-main
git merge main
# Verify build & tests
cargo check
```

---

## 3. Modular Architecture (`xai-grok-custom`)

All team-specific extensions reside in an isolated crate inside the Cargo workspace.

### 3.1 Directory Structure
```text
crates/codegen/xai-grok-custom/
├── Cargo.toml
└── src/
    ├── lib.rs
    ├── prompt/       # Custom System Prompts, Persona & Team Guidelines
    ├── provider/     # Custom LLM API Endpoints & Gateway Adaptors
    └── tools/        # Custom Built-in Tools & Automation Command Handlers
```

### 3.2 Integration & Hook Points
To connect `xai-grok-custom` with `grok-build` core without scattering modifications:
1. **Tool Registration Hook**:
   - Location: `crates/codegen/xai-grok-tools`
   - Action: Include `xai-grok-custom::tools::register_custom_tools(...)` during tool discovery.
2. **Agent Initializer Hook**:
   - Location: `crates/codegen/xai-grok-agent/src/builder.rs`
   - Action: Apply custom system prompt modifiers from `xai-grok-custom::prompt::apply_custom_rules(...)`.
3. **Workspace Cargo Manifest**:
   - Location: Top-level `Cargo.toml`
   - Action: Add `"crates/codegen/xai-grok-custom"` to `workspace.members`.

---

## 4. Verification Plan

1. **Workspace Compilation Test**: Run `cargo check --workspace` to verify workspace integration.
2. **Upstream Merge Dry-Run**: Verify that `git merge main` into `custom-main` produces zero conflicts outside hook lines.
3. **Custom Crate Unit Testing**: Run `cargo test -p xai-grok-custom` to validate custom tools and prompt generators.
