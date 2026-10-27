from dataclasses import dataclass


@dataclass
class Usage:
    prompt: int = 0
    cached: int = 0
    completion: int = 0


class ProviderError(Exception):
    def __init__(self, code: str, status: int = 502):
        super().__init__(code)
        self.code, self.status = code, status
