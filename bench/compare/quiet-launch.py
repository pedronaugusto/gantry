"""Use the prepared virtualenv interpreter, independent of entry-point shebangs."""
import runpy
runpy.run_module('pydeps', run_name='__main__')
