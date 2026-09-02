config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# 일부 legacy module 변수는 외부 caller 호환성을 위해 유지한다. 실제 제거는 별도 major
# interface change에서 수행하므로 repository gate에서는 unused declaration만 제외한다.
rule "terraform_unused_declarations" {
  enabled = false
}
