# Platform image publishing

The platform publisher copies reviewed Istio multi-architecture images into a dedicated immutable private
ECR repository. It attests the approved mirror operation, not Istio's build provenance or an unverified
upstream signature. Application image provenance and SPDX policies remain independent.

## Prerequisites and ownership

- Apply the reviewed shared identity root through the platform Terraform owner. The new ECR repository
  and publisher role are separate from application repositories and build/attestation roles.
- Configure the actual fork owner/repository numeric IDs in `platform_image_publisher`; read metadata
  with `gh api repos/OWNER/EKS-infra` and `gh api users/OWNER`. Identity values are not secrets.
- GitHub environment `production` must restrict deployments to `main`, require an independent reviewer
  and prevent self-review. This protection is an external prerequisite; a YAML environment name alone
  does not enforce approval. The IAM subject contains this environment, not a branch claim.
- Set Actions Variables `AWS_REGION`, `PLATFORM_ISTIO_PROXY_REPOSITORY_URL`, and
  `PLATFORM_IMAGE_PUBLISHER_ROLE_ARN` from the exact Terraform outputs. No AWS static access key is needed.
- Add the platform ECR ARN to the Sigstore controller's explicit read allowlist. Workload node image pull
  permissions and outbound access to ECR/S3 are separate from the admission reader's permissions.

## Publication and activation

1. Review both upstream index digests and amd64/arm64 child digests in `platform-images.lock.json`. Keep
   the matching GitOps lock and injection values synchronized. Changes require a normal protected PR.
2. After the engineer pushes and merges, manually dispatch `publish-platform-images.yml` on `main`.
   This uploads images and signed custom attestations; it is not a read-only command.
3. Review the protected job. The runner verifies its pinned crane archive before executing it, verifies
   the source index and children, copies all architectures without overwriting an existing tag, and
   verifies the target index and children before generating a predicate.
4. A successful registry copy is not sufficient. Both custom attestation generation and subsequent
   `gh attestation verify` must succeed. Attestation absence or a failed retry keeps activation blocked.
5. Supply the repository URL, publisher identity and exact digests to GitOps. Use its mirror activation
   check to verify actual OCI attestations and admission/controller readiness before namespace opt-in.
6. Istio injection must override both proxy and proxy-init image settings. Verify the fully injected
   Pod, not just the application Helm template. Unknown registries and image digests remain denied.

The custom predicate type is a stable schema identifier owned by this project; forks keep that schema
URI but must change the separately verified publisher workflow and numeric repository identity. A new
upstream digest cannot be blessed by changing only the destination tag: locks and exact-image admission
policy must be reviewed together. The predicate is not a vulnerability report or vendor authenticity proof.
If upstream signature verification is an organization requirement, the platform owner must obtain and
verify genuine signature material before approving a new lock; never fabricate an upstream attestation.

## Failure and rollback

Digest, architecture, registry, publisher or attestation errors abort publication or activation. External
tool stderr is suppressed by the mirror helper to avoid credential leakage; inspect the failing stage
with the approved platform identity, without enabling shell xtrace or printing registry credentials.
Existing immutable tags are never overwritten. Retain stable/candidate digests and their OCI referrers
until no control-plane, gateway, proxy or rollback revision uses them. Do not apply a generic untagged
artifact lifecycle expiry to signatures/attestations. ECR deletion is separately reviewed and protected.

Local mocked registry tests establish command, identity and content checks only. Registry copy, GitHub
OIDC/attestation, ECR scanning/pull, and actual Sigstore admission remain `LIVE_NOT_VERIFIED` until executed.

## References

- [crane copy](https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane_copy.md)
- [Pinned generic GitHub attestation inputs](https://github.com/actions/attest/blob/1e69f48acb82d1966a394da916b4c1698aa569d6/action.yml)
- [Istio image signature verification](https://istio.io/latest/docs/ops/best-practices/image-signing-validation/)
