#pragma once

#include <map>

#include "util.hh"

struct Config
{
    std::map<std::string, std::string> options;

    Config()
    {
        using namespace nix;

        /* Read hydra.conf. */
        auto hydraConfigFile = getEnv("HYDRA_CONFIG");
        if (pathExists(hydraConfigFile)) {

            for (auto line : tokenizeString<Strings>(readFile(hydraConfigFile), "\n")) {
                line = trim(string(line, 0, line.find('#')));

                auto eq = line.find('=');
                if (eq == std::string::npos) continue;

                auto key = trim(std::string(line, 0, eq));
                auto value = trim(std::string(line, eq + 1));

                if (key == "") continue;

                options[key] = value;
            }
        }
    }

    std::string getStrOption(const std::string & key, const std::string & def = "")
    {
        auto i = options.find(key);
        return i == options.end() ? def : i->second;
    }

    uint64_t getIntOption(const std::string & key, uint64_t def = 0)
    {
        auto i = options.find(key);
        return i == options.end() ? def : std::stoll(i->second);
    }

    bool getBoolOption(const std::string & key, bool def = false)
    {
        auto i = options.find(key);
        return i == options.end() ? def : (i->second == "true" || i->second == "1");
    }
};
