# Workload identity: IRSA
Use IRSA for this release because exact ServiceAccount trusts and rollback paths
already exist. Argo controllers use ServiceAccount/RBAC; they are not Access Entries.
The migration trigger is accepted cross-cluster or cross-account recovery. Migration
requires destination Pod Identity association, in-Pod STS credential acquisition,
a rollback window, and removal of the superseded IRSA annotation after that window.
Never enable both mechanisms on the same ServiceAccount.
