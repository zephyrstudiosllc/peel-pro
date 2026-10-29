"""EXPLICIT synthetic positive commerce adapter for retained non-commerce tests.

Never imported by service/deployment. These existing tests isolate identity,
MCP, persistence and continuity; the real CommerceAdmission tests cover payment.
"""
from types import SimpleNamespace
from uuid import NAMESPACE_URL,uuid5
from peel_watch_relay.broker import encode


class PositiveCommerceFixture:
    def __init__(self,clock):self.clock=clock
    def permit(self,identity):
        return SimpleNamespace(id=str(uuid5(NAMESPACE_URL,"test-only-paid:"+identity)),
            binding=encode({"enrollmentID":str(uuid5(NAMESPACE_URL,"test-only-enrollment:"+identity))}),wall_expiry=int(self.clock())+300)
    def require_connect(self,account,device):return self.permit(account.principal+device.device_id)
    def bind_route(self,*a):pass
    def require_route(self,account,route,permit_id=None):return self.permit(route["id"])
    def effective_expiry(self,permit):return permit.wall_expiry
