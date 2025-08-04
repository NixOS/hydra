#pragma once

#include <pqxx/pqxx>

#include <nix/util/environment-variables.hh>
#include <nix/util/util.hh>


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


class receiver
{
    std::optional<std::string> status;
    pqxx::connection & conn;

public:

    receiver(pqxx::connection_base & c, const std::string & channel)
        : conn(static_cast<pqxx::connection &>(c))
    {
        conn.listen(channel, [this](pqxx::notification n) {
            status = std::string(n.payload);
        });
    }

    std::optional<std::string> get() {
        auto s = status;
        status = std::nullopt;
        return s;
    }
};
