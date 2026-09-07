.PHONY: check test test-terraform policy

# Local static validation; no remote state or AWS credentials are used.
check:
	terraform fmt -check -recursive
	tflint --recursive --config="$(CURDIR)/.tflint.hcl"
	$(MAKE) policy test

policy:
	conftest verify --policy policy/terraform

test:
	python3 -B -m unittest discover -s tests -p 'test_*.py' -v
	bash tests/saved-plan.sh

# Native tests remain beside the modules whose security properties they verify.
test-terraform:
	@set -eu; for root in $$(find modules environments terraform -name '*.tftest.hcl' | sed 's|/tests/[^/]*$$||' | sort -u); do \
	  terraform -chdir="$$root" init -backend=false -input=false -no-color; \
	  terraform -chdir="$$root" validate -no-color; \
	  terraform -chdir="$$root" test -no-color; \
	done
