from typing import Optional
from pydantic import BaseModel, Field


class CreateAccount(BaseModel):
    service: str
    days: Optional[int] = Field(default=None, ge=1, le=30)
    hours: Optional[int] = Field(default=None, ge=1, le=720)
    username: Optional[str] = None
    password: Optional[str] = None
    max_sessions: int = Field(default=1, ge=1, le=100)


class RenewAccount(BaseModel):
    days: int = Field(ge=1, le=30)
