"""Outbound allowlist for the bridge process, independent of cloud credentials."""
import ipaddress
import sys


def restrict_to_hub(address):
    address = str(ipaddress.IPv4Address(address))

    def audit(event, args):
        if event == 'socket.connect':
            destination = args[1]
        elif event == 'socket.sendto':
            destination = args[2]
        elif event == 'socket.getaddrinfo':
            if args[0] != address:
                raise PermissionError('Bridge permits only the configured IR hub')
            return
        else:
            return
        if not isinstance(destination, tuple) or destination[:2] != (address, 6668):
            raise PermissionError('Bridge permits only the configured IR hub on TCP 6668')

    sys.addaudithook(audit)
