#pragma once

#include <pqxx/pqxx>

#include "environment-variables.hh"
#include "util.hh"


struct Connection : pqxx::connection
{
    Connection() : pqxx::connection(getFlags()) { };

    std::string getFlags()
    {
        using namespace nix;
        auto s = getEnv("HYDRA_DBI").value_or("dbi:Pg:dbname=hydra;");

        std::string lower_prefix = "dbi:Pg:";
        std::string upper_prefix = "DBI:Pg:";

        if (hasPrefix(s, lower_prefix) || hasPrefix(s, upper_prefix)) {
            return concatStringsSep(" ", tokenizeString<Strings>(std::string(s, lower_prefix.size()), ";"));
        }

        throw Error("$HYDRA_DBI does not denote a PostgreSQL database");
    }
};


class receiver : public pqxx::notification_receiver
{
    std::optional<std::string> status;

public:

    receiver(pqxx::connection_base & c, const std::string & channel)
        : pqxx::notification_receiver(c, channel) { }

    void operator() (const std::string & payload, int pid) override
    {
        status = payload;
    };

    std::optional<std::string> get() {
        auto s = status;
        status = std::nullopt;
        return s;
    }
};
