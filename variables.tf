variable "rfc3339" {
  description = "An explicit RFC 3339 timestamp to pin. When null the timestamp is captured at first apply and stored in state."
  type        = string
  default     = null
}

variable "triggers" {
  description = "A map of arbitrary values. Any change causes the timestamp to be regenerated on the next apply."
  type        = map(string)
  default     = {}
  nullable    = false
}
