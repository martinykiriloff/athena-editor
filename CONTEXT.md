# Athena — Domain Glossary

Vocabulary for talking about Athena. Terms only; no implementation detail.

## Feature

A capability built into Athena itself, implemented natively, and enabled or
disabled through Settings. What a VS Code user would call an "extension" or
"plugin" is, in Athena, always a Feature. There is no third-party plugin
mechanism.

- Prettier formatting, SFCC cartridge upload and Drizzle completion are Features.
- "Install the GitLens plugin" is not a thing Athena does; the equivalent is
  "Athena has the Git History Feature".

## VS Code Extension

Software that runs inside VS Code's extension host. Athena never runs one.
When someone names a VS Code Extension as something they want, they are
naming the *capability* it provides, which becomes a Feature.

## VS Code Parity

Athena's target is not VS Code the product but the daily fullstack-web
workflow of a VS Code user: the editor, terminal, git, search, language
tooling, debugging and the handful of Features that workflow depends on.
General-purpose VS Code capabilities outside that workflow are out of scope
by default.

## Cartridge

An SFCC code unit: a directory whose name is the cartridge name and which
contains a `cartridge/` folder holding controllers, scripts, templates and
static assets. A workspace holds many Cartridges, usually under one
`cartridges/` folder. A Cartridge is uploaded and debugged as a unit.

## Script Path

How the SFCC sandbox names a file inside a Cartridge: a slash-separated path
that starts with the cartridge name, e.g. `/app_storefront/cartridge/controllers/Cart.js`.
Breakpoints and stack frames use Script Paths; the editor uses local file
paths. Translating between the two requires knowing where each Cartridge
lives on disk.

## Code Version

The named deployment slot on an SFCC sandbox that Cartridges are uploaded to
and that the debugger attaches to. Only one Code Version is active per
sandbox at a time.

## Launch Configuration

A named way of starting a debug session. Athena reads VS Code's
`.vscode/launch.json` and also offers built-in configurations when the
workspace makes one obvious, for example an SFCC configuration when a
`dw.json` is present.
