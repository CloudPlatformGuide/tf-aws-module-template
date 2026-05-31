from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck


class TimestampHasTriggers(BaseResourceCheck):
    def __init__(self):
        super().__init__(
            name="Ensure time_static defines triggers for controlled refresh",
            id="CKV_CUSTOM_TIME_1",
            categories=[CheckCategories.GENERAL_SECURITY],
            supported_resources=["time_static"],
        )

    def scan_resource_conf(self, conf):
        triggers = conf.get("triggers")
        # triggers missing, null, or explicitly set to an empty map all fail.
        if not triggers or triggers in ([None], [{}], [[]]):
            return CheckResult.FAILED
        return CheckResult.PASSED


check = TimestampHasTriggers()
