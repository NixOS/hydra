function makeTreeCollapsible(tab) {
    /*** Tree toggles in logfiles. ***/

    /* Set the appearance of the toggle depending on whether the
       corresponding subtree is initially shown or hidden. */
    tab.find(".tree-toggle").map(function() {
        if ($(this).siblings("ul:hidden").length == 0) {
            $(this).text("-");
        } else {
            $(this).text("+");
        }
    });

    /* When a toggle is clicked, show or hide the subtree. */
    tab.find(".tree-toggle").click(function() {
        if ($(this).siblings("ul:hidden").length != 0) {
            $(this).siblings("ul").show();
            $(this).text("-");
        } else {
            $(this).siblings("ul").hide();
            $(this).text("+");
        }
    });

    /* Implementation of the expand all link. */
    tab.find(".tree-expand-all").click(function() {
        tab.find(".tree-toggle", $(this).parent().siblings(".tree")).map(function() {
            $(this).siblings("ul").show();
            $(this).text("-");
        });
    });

    /* Implementation of the collapse all link. */
    tab.find(".tree-collapse-all").click(function() {
        tab.find(".tree-toggle", $(this).parent().siblings(".tree")).map(function() {
            $(this).siblings("ul").hide();
            $(this).text("+");
        });
    });
}

$(document).ready(function() {
    $("table.clickable-rows").click(function(event) {
        if ($(event.target).closest("a").length) return;
        link = $(event.target).parents("tr").find("a.row-link");
        if (link.length == 1)
          window.location = link.attr("href");
    });

    bootbox.setDefaults({ animate: false });

    /* Enable popovers (and allow table and teletype elements in them). */
    $.fn.popover.Constructor.Default.whiteList.table = [];
    $.fn.popover.Constructor.Default.whiteList.thead = []
    $.fn.popover.Constructor.Default.whiteList.tbody = [];
    $.fn.popover.Constructor.Default.whiteList.tr = [];
    $.fn.popover.Constructor.Default.whiteList.th = [];
    $.fn.popover.Constructor.Default.whiteList.td = [];
    $.fn.popover.Constructor.Default.whiteList.tt = [];
    $(".hydra-popover").popover({});

    /* Activates tab according to URL anchor. */
    if (window.location.hash) {
        setTimeout(function () { $('.nav-tabs > .nav-item:not(.dropdown) a[href="' + window.location.hash + '"]').trigger('show.bs.tab'); }, 0);
        $('.nav-tabs > .nav-item:not(.dropdown) a[href="' + window.location.hash + '"]').tab('show');
    }

    $('.nav-tabs').each(function() {
        if ($('.nav-item:not(.dropdown) a.active',this).length == 0)
            $('.nav-item:not(.dropdown) a',this).first().tab('show');
    });

    $('.nav-tabs > .nav-item:not(.dropdown) a[href^="#"]').on('click', function() {
        history.replaceState(null, null, window.location.href.split("#")[0] + $(this).attr("href"));
    });

    /* Automatically set Bootstrap radio buttons from hidden form controls. */
    $('div[data-toggle="buttons-radio"] input[type="hidden"]').map(function(){
        $('button[value="' + $(this).val() + '"]', $(this).parent()).addClass('active');
    });

    /* Automatically update hidden form controls from Bootstrap radio buttons. */
    $('div[data-toggle="buttons-radio"] .btn').click(function(){
        $('input', $(this).parent()).val($(this).val());
    });

    $(".star").click(function(event) {
        var star = $(this);
        var active = star.text() != '★';
        requestJSON({
            url: star.attr("data-post"),
            data: active ? "star=1" : "star=0",
            type: 'POST',
            success: function(res) {
                if (active) {
                    star.text('★');
                } else {
                    star.text('☆');
                }
            }
        });
    });

    /* Makes dates more user friendly. */
    // Friendly date format
    var DATE_FORMAT = "YYYY-MM-DD HH:mm:ss";
    // Local timezone offset to display.
    var tz = moment().format("Z");
    $("time.date").each(function(i, el) {
        var el = $(el);
        var localTime = moment(el.data("timestamp"), "%X");
        var hydraTime = el.attr("title");
        if (el.hasClass("is-absolute")) {
            el.attr( "title", [
                "Adjusted to local time (" + tz + ")",
                "Other timezones:",
                "  UTC: " + localTime.clone().utc().format(DATE_FORMAT),
                "  As Hydra reported: " + hydraTime,
            ].join("\n"));
            el.text(localTime.format(DATE_FORMAT));
            el.addClass("is-local");
        }
        else if (el.hasClass("is-relative")) {
            el.attr( "title", [
                "Local (" + tz + "): " + localTime.format(DATE_FORMAT),
                "UTC: " + localTime.clone().utc().format(DATE_FORMAT),
                "As Hydra reported: " + hydraTime,
            ].join("\n"));
            el.addClass("is-local");
        }
    });

    [...document.getElementsByTagName("iframe")].forEach((element) => {
        element.contentWindow.addEventListener("DOMContentLoaded", (_) => {
            element.style.height = element.contentWindow.document.body.scrollHeight + 'px';
        })
    })
});

var tabsLoaded = {};

function makeLazyTab(tabName, uri, callback) {
    $('.nav-tabs').bind('show.bs.tab', function(e) {
        var pattern = /#.+/gi;
        var id = e.target.toString().match(pattern)[0];
        if (id == '#' + tabName && !tabsLoaded[id]) {
          tabsLoaded[id] = 1;
          $('#' + tabName).load(uri, function(response, status, xhr) {
            var lazy = xhr.getResponseHeader("X-Hydra-Lazy") === "Yes";
            var tab = $('#' + tabName);
            if (status == "error" && !lazy) {
              tab.html("<div class='alert alert-error'>Error loading tab: " + xhr.status + " " + xhr.statusText + "</div>");
            }
            else {
              tab.html(response);
              if (callback) {
                callback(tab);
              }
            }
          });
        }
    });
};

function escapeHTML(s) {
    return $('<div/>').text(s).html();
};

function requestFile(args) {
    if (!("error" in args)) {
        args.error = function(data) {
            json = {};
            try {
                if (data.responseText)
                    json = $.parseJSON(data.responseText);
            } catch (err) {
            }
            if (json.error)
                bootbox.alert(escapeHTML(json.error));
            else if (data.responseText)
                bootbox.alert("Server error: " + escapeHTML(data.responseText));
            else
                bootbox.alert("Unknown server error!");
            if (args.postError) args.postError(data);
        };
    }
    return $.ajax(args);
};

function requestJSON(args) {
    args.dataType = 'json';
    requestFile(args);
};

function requestPlainFile(args) {
    args.dataType = 'text';
    /* Remove the X-Requested-With header, which would turn trigger
       CORS checks for this request.
       http://stackoverflow.com/a/24719409/6747243
    */
    args.xhr = function() {
        var xhr = jQuery.ajaxSettings.xhr();
        var setRequestHeader = xhr.setRequestHeader;
        xhr.setRequestHeader = function(name, value) {
            if (name == 'X-Requested-With') return;
            setRequestHeader.call(this, name, value);
        }
        return xhr;
    };
    requestFile(args);
};

function redirectJSON(args) {
    args.success = function(data) {
        window.location = data.redirect;
    };
    return requestJSON(args);
};

function backToReferrer() {
    // FIXME: should only do this if the referrer is another Hydra
    // page.
    window.location = document.referrer;
}

function showChart(id, dataUrl, yaxis) {
    requestJSON({
      url: dataUrl,
      success: function(data) {
        var d = [];
        var maxTime = 0;
        var minTime = Number.MAX_SAFE_INTEGER;
        data.forEach(function(x) {
          var t = x.timestamp * 1000;
          d.push(
              [t,
               yaxis == "mib" ? x.value / (1024.0 * 1024.0) : x.value
              ]);
          maxTime = Math.max(t, maxTime);
          minTime = Math.min(t, minTime);
        });

        var options = {
          xaxis: { mode: "time" },
          yaxis: { min: 0 },
          selection: { mode: "x" },
          points: { show: true },
          lines: { show: true },
          grid: {
            clickable: true,
            hoverable: true,
            hoverFill: '#444',
            hoverRadius: 4,
          },
        };

        var plot = $.plot($("#" + id + "-chart"), [d], options);

        var overview = $.plot($("#" + id + "-overview"), [d], {
          series: {
            lines: { show: true, lineWidth: 1 },
            shadowSize: 0
          },
          xaxis: { ticks: [], mode: "time" },
          yaxis: { ticks: [], min: 0, autoscaleMargin: 0.1 },
          selection: { mode: "x" }
        });

        // now connect the two

        $("#" + id + "-chart").bind("plotselected", function (event, ranges) {
          var ymax = 0;
          d.forEach(function(x) {
            if (x[0] < ranges.xaxis.from) return;
            if (x[0] > ranges.xaxis.to) return;
            ymax = Math.max(x[1], ymax);
          });

          // do the zooming
          plot = $.plot($("#" + id + "-chart"), [d],
            $.extend(true, {}, options, {
              xaxis: { min: ranges.xaxis.from, max: ranges.xaxis.to },
              yaxis: { min: 0, max: ymax * 1.1 }
            }));

          // don't fire event on the overview to prevent eternal loop
          overview.setSelection(ranges, true);
        });

        $("#" + id + "-overview").bind("plotselected", function (event, ranges) {
          plot.setSelection(ranges);
        });

        $("#" + id + "-chart").bind("plotclick", function (e, pos, item) {
          if (item) {
            plot.highlight(item.series, item.datapoint);
            buildid = data[item.dataIndex].id;
            window.location = "/build/"+buildid;
          }
        });

        $("#" + id + "-chart").bind("plothover", function (event, pos, item) {
            if (item) {
                var i = data[item.dataIndex];
                var date = new Date(i.timestamp * 1000);
                var s =
                    "Build <em>" + i.id + "</em><br/>"
                    + "on " + date.getFullYear() + "-" + (date.getMonth() + 1) + "-" + date.getDate() + ""
                    + ":<br/><strong>" + i.value
                    + (i.unit != null ? " " + i.unit : "") + "</strong>";
                $("#flot-tooltip")
                    .html(s)
                    .css({top: item.pageY + 10, left: item.pageX + 10})
                    .show();
            } else
                $("#flot-tooltip").hide();
        });

        // Zoom in to the last two months by default.
        plot.setSelection({ xaxis: { from: Math.max(minTime, maxTime - 60 * 24 * 60 * 60 * 1000), to: maxTime } });
      }
    });
}
