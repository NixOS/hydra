#! /usr/bin/env nix-shell
#! nix-shell -i python3 -p python35Packages.requests2

import requests
import time
import json
import http
import typing
from typing import Union, Dict

# ------------------------------------------------------------------------------

username = "remyg"
password = "hunter2"

# ------------------------------------------------------------------------------

def hydraURL(endpoint : str):
    return "http://127.0.0.1:3000/" + endpoint

jar = http.cookiejar.CookieJar()

RequestData = Union[None, bytes, Dict[str, str]]

def hydraGET(endpoint : str, accept : str = "application/json"):
    global jar
    headers = {"Accept": accept, "Referer": hydraURL("")}
    r = requests.get(hydraURL(endpoint), cookies = jar, headers = headers)
    jar = r.cookies
    return r

def hydraPUT(endpoint : str, data : RequestData):
    global jar
    headers = {"Accept": "application/json", "Referer": hydraURL("")}
    r = requests.put(hydraURL(endpoint),
                     cookies = jar,
                     data    = data,
                     headers = headers)
    jar = r.cookies
    return r

def hydraPOST(endpoint : str, data : RequestData):
    global jar
    headers = {"Accept": "application/json", "Referer": hydraURL("")}
    r = requests.post(hydraURL(endpoint),
                      cookies = jar,
                      data    = data,
                      headers = headers)
    jar = r.cookies
    return r

def hydraDELETE(endpoint : str):
    global jar
    headers = {"Accept": "application/json", "Referer": hydraURL("")}
    r = requests.delete(hydraURL(endpoint), cookies = jar, headers = headers)
    jar = r.cookies
    return r

# ------------------------------------------------------------------------------

def hydraLogin():
    print("Logging in")
    r = hydraPOST("login", {"username": username, "password": password})
    assert r.status_code == 200
    return r

def hydraLogout():
    print("Logging out")
    r = hydraPOST("logout", {})
    assert r.status_code == 204
    return r

def hydraDeleteProject(project : str):
    print("Deleting project: " + project)
    return hydraDELETE("project/" + project)

def hydraDeleteJobset(project : str, jobset : str):
    print("Deleting jobset:  " + project + ":" + jobset)
    return hydraDELETE("jobset/" + project + "/" + jobset)

def hydraDeleteAll():
    r = hydraGET("")
    assert r.ok

    for project in r.json():
        name = project["name"]
        for jobset in project["jobsets"]:
            hydraDeleteJobset(name, jobset)
        hydraDeleteProject(name)

    r = hydraGET("")
    assert r.json() == []

def test():
    hydraLogin()

    try:
        hydraDeleteAll()

        r = hydraPUT("project/sample",
                     {"enabled":     "1",
                      "hidden":      "0",
                      "displayname": "Sample",
                      "description": "foobar",
                      "owner":       "remyg",
                      "homepage":    "https://example.com",
                      "declfile":    "",
                      "decltype":    "boolean",
                      "declvalue":   "true"})
        assert r.ok

        r = hydraPUT("jobset/sample/default",
                     json.dumps({"enabled":       "0",
                                 "hidden":        "0",
                                 "nixexprpath":   "release.nix",
                                 "nixexprinput":  "src",
                                 "inputs":        {"src": {"type": "path", "value": "/foo/bar"}},
                                 "checkinterval": "3600",
                                 "description":   "rofl"}).encode("utf-8"))
        assert r.ok

        hydraDeleteAll()

        # r = hydraGET("")
        # print(r)
        # print(r.text)
        #
        # r = hydraDELETE("project/sample")
        #
        # r = hydraGET("")
        # print(r)
        # print(r.text)
    finally:
        hydraLogout()

# ------------------------------------------------------------------------------

test()

# ------------------------------------------------------------------------------
