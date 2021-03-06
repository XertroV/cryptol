import os

from cryptol import CryptolConnection, CryptolContext, cry
import cryptol
import cryptol.cryptoltypes

dir_path = os.path.dirname(os.path.realpath(__file__))

c = cryptol.connect("cabal new-exec --verbose=0 cryptol-remote-api")

c.change_directory(dir_path)

c.load_file("Foo.cry")

val = c.evaluate_expression("x").result()

assert c.call('add', b'\0', b'\1').result() == b'\x01'
assert c.call('add', bytes.fromhex('ff'), bytes.fromhex('03')).result() == bytes.fromhex('02')


cryptol.add_cryptol_module('Foo', c)
from Foo import *
assert add(b'\2', 2) == b'\4'
