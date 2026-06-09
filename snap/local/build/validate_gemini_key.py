#!/usr/bin/env python3
"""Deprecated. Redirects to validate_llm_key.py.

You can safely delete this file.
"""
import sys
import os

# Redirect execution to validate_llm_key.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate_llm_key

if __name__ == "__main__":
    sys.exit(validate_llm_key.main())
