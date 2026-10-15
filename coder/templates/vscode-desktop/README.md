# VS Code Desktop with Selkies

Kubernetes workspace with the full Microsoft VS Code desktop streamed through
Selkies. Coder exposes the desktop as a path-based workspace app, so no wildcard
DNS name or certificate is required.

The persistent `/config` volume uses the replicated LINSTOR storage class and is
labelled for the daily Velero snapshot schedule. The Coder agent runs in a
separate container in the same Pod and sees the same workspace files.

This is the initial general-purpose template. Move it to the dedicated workspace
image/template repository when that repository is created.
