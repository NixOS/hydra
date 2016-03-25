$(document).ready(function() {

    /*** Tree toggles in logfiles. ***/

    /* Set the appearance of the toggle depending on whether the
       corresponding subtree is initially shown or hidden. */
    $(".tree-toggle").map(function() {
        if ($(this).siblings("ul:hidden").length == 0) {
            $(this).text("-");
        } else {
            $(this).text("+");
        }
    });

    /* When a toggle is clicked, show or hide the subtree. */
    $(".tree-toggle").click(function() {
        if ($(this).siblings("ul:hidden").length != 0) {
            $(this).siblings("ul").show();
            $(this).text("-");
        } else {
            $(this).siblings("ul").hide();
            $(this).text("+");
        }
    });

    /* Implementation of the expand all link. */
    $(".tree-expand-all").click(function() {
        $(".tree-toggle", $(this).parent().siblings(".tree")).map(function() {
            $(this).siblings("ul").show();
            $(this).text("-");
        });
    });

    /* Implementation of the collapse all link. */
    $(".tree-collapse-all").click(function() {
        $(".tree-toggle", $(this).parent().siblings(".tree")).map(function() {
            $(this).siblings("ul").hide();
            $(this).text("+");
        });
    });

    $("table.clickable-rows").click(function(event) {
        if ($(event.target).closest("a").length) return;
        link = $(event.target).parents("tr").find("a.row-link");
        if (link.length == 1)
          window.location = link.attr("href");
    });

    bootbox.animate(false);

    $(".hydra-popover").popover({});

    $(function() {
        if (window.location.hash) {
            $(".nav-tabs a[href='" + window.location.hash + "']").tab('show');
        }

        /* If no tab is active, show the first one. */
        $(".nav-tabs").each(function() {
            if ($("li.active", this).length > 0) return;
            $("a", $(this).children("li:not(.dropdown)").first()).tab('show');
        });

        /* Ensure that pressing the back button on another page
           navigates back to the previously selected tab on this
           page. */
        $('.nav-tabs').bind('show', function(e) {
            var pattern = /#.+/gi;
            var id = e.target.toString().match(pattern)[0];
            history.replaceState(null, "", id);
        });
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
});

var tabsLoaded = {};

function makeLazyTab(tabName, uri) {
    $('.nav-tabs').bind('show', function(e) {
        var pattern = /#.+/gi;
        var id = e.target.toString().match(pattern)[0];
        if (id == '#' + tabName && !tabsLoaded[id]) {
          tabsLoaded[id] = 1;
          $('#' + tabName).load(uri, function(response, status, xhr) {
            if (status == "error") {
              $('#' + tabName).html("<div class='alert alert-error'>Error loading tab: " + xhr.status + " " + xhr.statusText + "</div>");
            }
          });
        }
    });
};

function escapeHTML(s) {
    return $('<div/>').text(s).html();
};

function requestJSON(args) {
    args.dataType = 'json';
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
    return $.ajax(args);
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

        // Zoom in to the last two months by default.
        plot.setSelection({ xaxis: { from: Math.max(minTime, maxTime - 60 * 24 * 60 * 60 * 1000), to: maxTime } });
      }
    });
}
