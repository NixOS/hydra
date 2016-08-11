/* Reduce a list of [key, value] arrays into a a closure that returns an
 * object. */
function reduceDischargers(dischargers) {
  return function() {
    return dischargers.reduce(function(values, discharger) {
      var discharged = discharger();
      if (discharged[1] === null) return values;
      values[discharged[0]] = discharged[1];
      return values;
    }, {});
  };
}

/* Push a key (optionally can be a function as well) and a function for the
 * value into a list of dischargers. */
function pushDischarger(dischargers, key, fun) {
  dischargers.push(function() {
    if (typeof key === "function")
      return [key(), fun()];
    else
      return [key, fun()];
  });
}

/* Create a single key/value field for the "attrset" property type. */
function createAttr(dischargers, root, key, val) {
  var deleteButton = $('<button/>', {
    type: 'button',
    class: 'btn btn-warning btn-mini',
  });
  deleteButton.append('<i class="icon-trash icon-white"></i>');

  var keyElem = $('<dt/>');
  var keyInput = $('<input/>', {type: 'text', value: key});
  keyElem.append(deleteButton, keyInput);

  var dataElem = $('<dd/>');
  var dataInput = $('<input/>', {type: 'text', value: val});
  dataElem.append(dataInput);

  root.append(keyElem, dataElem);

  deleteButton.click(function() {
    keyInput.val("");
    dataInput.val("");
    keyElem.remove();
    dataElem.remove();
  });

  pushDischarger(dischargers, function() {
    return keyInput.val();
  }, function() {
    var dispatched = dataInput.val();
    return dispatched === "" ? null : dispatched;
  });
}

/* Create all the fields necessary for a certain type of property. */
function createPropertyType(spec, value) {
  switch (spec.type) {
    case "bool":
      var boolInput = $('<input/>', {type: 'checkbox'});
      boolInput.prop('checked', value);
      var defVal = "defaultValue" in spec ? spec.defaultValue : false;
      return {
        elem: boolInput,
        discharge: function() {
          var discharged = boolInput.is(':checked');
          if (discharged === defVal)
            return null;
          else
            return discharged;
        },
      };
    case "attrset":
      var container = $('<div/>');
      var existing = $('<dl/>', {class: 'properties'});
      var dischargers = [];
      for (key in value) {
        createAttr(dischargers, existing, key, value[key]);
      }
      var addButton = $('<button/>', {
        type: 'button',
        class: 'btn btn-success btn-mini',
      });
      addButton.text('Add a new attribute');
      addButton.prepend('<i class="icon-plus icon-white"></i>');
      addButton.click(function() {
        createAttr(dischargers, existing);
        return false;
      });
      container.append(existing, addButton);
      return {
        elem: container,
        discharge: function() {
          var discharged = reduceDischargers(dischargers)();
          if (jQuery.isEmptyObject(discharged))
            return null;
          else
            return discharged;
        }
      };
    default:
      var defInput = $('<input/>', {type: 'text', value: value});
      return {
        elem: defInput,
        discharge: function() {
          var discharged = defInput.val();
          if (discharged === "")
            return null;
          else
            return discharged;
        }
      };
  }
}

/* Create a form inputs for a specific property and return an object
 * consisting of the DOM element and the discharger function.
 */
function createProperty(spec, value) {
  var propType = createPropertyType(spec, value);
  var container = propType.elem;
  var discharger = propType.discharge;

  if ("properties" in spec) {
    container = $('<div/>');
    container.append(propType.elem);
    var subProperties = updateProperties(spec, false, {});

    if (propType.discharge() === null)
      subProperties.elem.hide();

    propType.elem.change(function() {
      if (propType.discharge() === null)
        subProperties.elem.hide();
      else
        subProperties.elem.show();
    });

    container.append(subProperties.elem);

    discharger = function() {
      var discharged = propType.discharge();
      if (discharged.value === null) {
        return null;
      } else return {
        value: discharged,
        children: subProperties.discharge()
      };
    }
  }

  return {
    elem: container,
    discharge: discharger
  }
}

/* Create a series of properties for the given spec and optionally its
 * pre-existing values and return an object of its DOM root element and the
 * discharger function.
 */
function updateProperties(spec, topLevel, propValues) {
  if (spec.hasOwnProperty('singleton')) {
    spec.singleton['required'] = true;
    var prop = createProperty(spec.singleton, propValues.value);
    return {
      elem: prop.elem,
      discharge: function() {
        return {value: prop.discharge()};
      }
    };
  } else {
    var container = $('<div/>');
    var elem = $('<dl/>', {class: 'properties'});
    var dischargers = [];
    var sortedKeys = Object.keys(spec.properties).sort(function(a, b) {
      var pa = spec.properties[a];
      var pb = spec.properties[b];
      if (pa.required && !pb.required) return -1;
      if (pb.required && !pa.required) return 1;
      return a.localeCompare(b);
    });
    var hasOptionals = false;
    for (var i in sortedKeys) {
      var name = sortedKeys[i];

      var label = $('<dt/>').text(spec.properties[name].label);
      if (!spec.properties[name].required) {
        label.prop('class', 'prop-optional');
        if (topLevel) label.hide();
        hasOptionals = true;
      } else {
        label.prop('class', 'prop-required');
      }
      elem.append(label);

      var prop = createProperty(spec.properties[name], propValues[name]);
      if ("help" in spec.properties[name])
        prop.elem.prop('title', spec.properties[name].help);
      var data = $('<dd/>').append(prop.elem);
      if (!spec.properties[name].required) {
        data.prop('class', 'prop-optional');
        if (topLevel) data.hide();
      } else {
        label.prop('class', 'prop-required');
      }
      elem.append(data);

      pushDischarger(dischargers, name, prop.discharge);
    }
    container.append(elem);
    if (topLevel && hasOptionals) {
      var showOptionals = $('<button/>', {
        type: 'button',
        class: 'btn btn-info btn-mini',
      });
      showOptionals.text('optional properties');
      showOptionals.prepend('<i class="icon-arrow-down icon-white"></i>');
      showOptionals.click(function() {
        var optionals = $(container).find('.prop-optional');
        var buttonIcon = $(showOptionals).find('i');
        if (optionals.is(':visible')) {
          buttonIcon.prop('class', 'icon-arrow-down icon-white');
          optionals.hide();
        } else {
          buttonIcon.prop('class', 'icon-arrow-up icon-white');
          optionals.show();
        }
        return false;
      });
      container.append(showOptionals);
    }

    return {
      elem: container,
      discharge: reduceDischargers(dischargers)
    };
  }
}

var dischargeMap = {};

function initProperties(node, pspec) {
  if (typeof initProperties.pspec === 'undefined')
    initProperties.pspec = pspec;

  var dischargers = {};
  node.find("[id^=input-][id$=-properties]").each(function() {
    var propContainer = $(this);
    var propField = propContainer.next();
    var propValues = JSON.parse(propField.val());
    var jobsetInput = $(this).closest(node);
    var typeField = jobsetInput.find("select[name$=-type]");
    var keyField = jobsetInput.find("input[name$=-name]")
    var newProps = updateProperties(
      initProperties.pspec[typeField.val()], true, propValues
    );
    propContainer.html(newProps.elem);
    dischargeMap[keyField.prop('name')] = newProps.discharge;
    typeField.change(function() {
      var newProps = updateProperties(
        initProperties.pspec[$(this).val()], true, propValues
      );
      propContainer.html(newProps.elem);
      dischargeMap[keyField.prop('name')] = newProps.discharge;
    });
  });
}
