# Notch Surface Model

The island now separates layout from content surface:

- `closed`: collapsed notch only
- `opened + sessionList`: manual browsing of attached sessions
- `opened + approvalCard`: auto-expanded approval interaction
- `opened + questionCard`: auto-expanded question interaction
- `opened + completionCard`: auto-expanded finished-task reminder

Routing rules:

- manual click or hover opens `sessionList`
- `permissionRequested` opens `approvalCard`
- `questionAsked` opens `questionCard`
- `sessionCompleted` opens `completionCard`

Auto-expanded cards are temporary surfaces:

- completion and failure cards auto-collapse after a short timeout
- completion and failure cards also collapse when the pointer leaves after first hover
- approval and question cards remain open until their actionable state resolves
- they are not rendered as inline actions inside the session list

This keeps the session list focused on navigation while question and approval
flows use dedicated notification surfaces.

The optional **Show only for notifications** behavior keeps the same logical
`closed` state and global notch/top-bar trigger geometry, but orders the overlay
panel out while closed. Hovering or clicking the trigger area orders the panel
back in for manual browsing; leaving a non-actionable surface closes and orders
it out again. The app process, bridge socket, hooks, and session monitoring stay
running independently of panel visibility.

The main DEV window is now a dedicated debug harness for these surfaces. It
drives inline mock previews for the session list plus approval, question, and
completion cards, and it can mirror the currently selected mock onto the real
island overlay for visual inspection.
