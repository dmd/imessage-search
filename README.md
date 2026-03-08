# Powerful search for your iMessages

This program should not need to exist. You should be able to search your Apple Messages within Messages.
But the built in search is awful, so here we are.

# Installation

It's just the single file you see here.

I refuse to deal with Python dependencies at all any more, even for something as simple as this
that has only one dependency (Flask). So either install Flask yourself and run with `python3 app.py`, or
install [uv](https://docs.astral.sh/uv/) and run with `./app.py`.

# Notes

It reads directly from your contacts and messages database. It opens in `mode=ro` (read only),
so no worries. Your terminal needs Full Disk Access, but if you're somehow using a terminal without
that enabled, you probably have other issues; consult a qualified rabbi.

