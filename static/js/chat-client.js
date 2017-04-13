/* var icons created by chat.lua */
var chatWrapper = document.getElementById('chatwrapper');
var chatMessages = document.getElementById('chatmessages');
var chatViewers = document.getElementById('chatviewers');
var chatInput = undefined;
var chatPickerList = undefined;
var accountList = undefined;
var commonmark = window.commonmark;
var parser = new commonmark.Parser();
var writer = new commonmark.HtmlRenderer();
var curInput;
var curAccount;
var tarAccount;
var ws;
var live = false;
var scroller = zenscroll.createScroller(chatMessages);

icons['irc'] = '<svg class="chaticon irc" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><path d="m 18.477051,7.5280762 h -4.390137 l -1.212891,4.9570308 h 4.060547 v 1.779786 h -4.521972 l -1.371094,5.550293 H 9.3408203 L 10.711914,14.264893 H 7.1523437 L 5.78125,19.815186 H 4.0805664 L 5.4516602,14.264893 H 1.5229492 V 12.485107 H 5.9130859 L 7.1259766,7.5280762 H 3.0654297 V 5.748291 H 7.5874023 L 8.9716797,0.18481445 H 10.672363 L 9.2880859,5.748291 h 3.5595701 l 1.384278,-5.56347655 h 1.700683 L 14.54834,5.748291 h 3.928711 z M 12.425781,7.501709 H 8.8134766 l -1.2392579,5.009766 h 3.6123043 z" /></svg>';

function findGetParameter(parameterName) {
    var result = null,
        tmp = [];
    location.search
    .substr(1)
        .split("&")
        .forEach(function (item) {
        tmp = item.split("=");
        if (tmp[0] === parameterName) result = true;
    });
    return result;
}

function atBottom(elem) {
    if( findGetParameter('widget') ) {
        return true;
    }
    return elem.scrollHeight - elem.scrollTop === elem.clientHeight;
}

function buildChatPickerList(accounts) {
    var chatPickerTest = document.getElementById('chatpickerlist');
    if(chatPickerTest !== undefined && chatPickerTest !== null) {
        chatWrapper.removeChild(chatPickerTest);
        chatPickerTest = undefined;
        chatPickerList = undefined;
    }

    chatPickerList = document.createElement('div');
    chatPickerList.id = 'chatpickerlist';
    var pickerMade = false;

    if(accounts !== undefined && accounts !== null) {
        accounts.forEach(function(account) {
            if(icons[account.network.name] && account.writable === true) {
                var chatPicker = document.createElement('div');
                chatPicker.className = 'chatpicker';
                chatPicker.innerHTML = icons[account.network.name] + '<p>' + account.name + '</p>';
                chatPicker.onclick = function() {
                    buildChatInput(account);
                };
                chatPickerList.appendChild(chatPicker);
                pickerMade = true;
            }
        });
    }

    if(pickerMade === false) {
        var chatPicker = document.createElement('div');
        chatPicker.className = 'chatpicker';
        if(live) {
            chatPicker.innerHTML = '<p>No accounts available</p>'
        }
        else {
            chatPicker.innerHTML = '<p>Stream not started</p>'
        }
        chatPicker.onclick = function() {
            buildChatInput(null);
        };
        chatPickerList.appendChild(chatPicker);
    }

    if(chatInput !== undefined) {
        chatWrapper.removeChild(chatInput);
        chatInput = undefined;
    }
    chatWrapper.appendChild(chatPickerList);
}

function buildChatBox(account, target_account) {
    var inputElement = document.createElement('input');
    var account_id = account.id
    var target_id = target_account.id
    inputElement.onkeypress = function(e) {
        var event = e || window.event;
        var charCode = event.which || event.keyCode;

        if(charCode === 13) {
            var text = inputElement.value;
            var parts = text.split(' ');
            var t = {
                account_id: account_id,
                cur_stream_account_id: target_id,
            };

            if(parts[0] == '/me') {
                parts.splice(0,1);
                text = parts.join(' ');
                t.type = 'emote';
            }
            else {
                t.type = 'text';
            }
            t.text = text;

            ws.send(JSON.stringify(t));
            inputElement.value = '';
        }
    };
    return inputElement;
}


function buildChatInput(account) {
    var chatInputTest = document.getElementById('chatinput');
    if(chatInputTest !== undefined && chatInputTest !== null) {
        chatWrapper.removeChild(chatInputTest);
        chatInputTest = undefined;
        chatInput = undefined;
    }

    chatInput = document.createElement('div');
    chatInput.id = 'chatinput';

    var nameElement = document.createElement('div');
    nameElement.className = 'name';

    var messageElement = document.createElement('div');
    messageElement.className = 'message';
    var inputElement;

    if(account !== null) {
        nameElement.innerHTML = icons[account.network.name] + '<p>' + account.name + '</p>';
        curAccount = account; // the 'from' account
        if(account.ready === true) {
            inputElement = buildChatBox(account, account);
            tarAccount = account;
            curInput = inputElement;
        }
        else {
            var liveAccounts = []
            accountList.forEach(function(a) {
              if(a.live === true && a.network.displayName.localeCompare(account.network.displayName) === 0) {
                  liveAccounts.push(a);
              }
            });
            if(liveAccounts.length == 1) {
                inputElement = buildChatBox(account,liveAccounts[0]);
                inputElement.disabled = true;
                tarAccount = liveAccounts[0];
                curInput = inputElement;
                ws.send(JSON.stringify({
                    type: 'writer',
                    account_id: account.id,
                    cur_stream_account_id: liveAccounts[0].id
                }));
            }
            else {
                inputElement = document.createElement('select');
                curInput = inputElement;
                var firstOpt = document.createElement('option');
                firstOpt.disabled = true;
                firstOpt.selected = true;
                firstOpt.innerHTML = 'Choose which stream to chat on'
                inputElement.appendChild(firstOpt);
                liveAccounts.forEach(function(a) {
                    var optionElement = document.createElement('option');
                    optionElement.innerHTML = a.name;
                    optionElement.value = a.id;
                    optionElement.tarAccount = a;
                    inputElement.appendChild(optionElement);
                });
                inputElement.onchange = function() {
                    inputElement.disabled = true;
                    liveAccounts.forEach(function(a) {
                      if (a.id === parseInt(inputElement.value,10)) {
                        tarAccount = a;
                        nameElement.innerHTML = icons[account.network.name] + '<p>' + account.name + ' -> ' + a.name + '</p>';
                      }
                    });
                    ws.send(JSON.stringify({
                        type: 'writer',
                        account_id: account.id,
                        cur_stream_account_id: inputElement.value,
                    }));
                };
            }
        }
        messageElement.appendChild(inputElement);
    }
    else {
        curAccount = undefined;
        curInput = undefined;
        if(live) {
            nameElement.innerHTML = '<p>No account chosen - click to choose</p>';
        }
        else {
            nameElement.innerHTML = '<p>Stream not started</p>';
        }
    }
    chatInput.appendChild(nameElement);
    chatInput.appendChild(messageElement);
    nameElement.firstChild.onclick = function() {
        buildChatPickerList(accountList);
    };
    if(chatPickerList !== undefined) {
        chatWrapper.removeChild(chatPickerList);
        chatPickerList = undefined;
    }
    if(chatWrapper !== null) {
        chatWrapper.appendChild(chatInput);
    }
    if(curInput !== undefined) {
        curInput.focus();
    }
}

function linkify(p) {
    var w;
    var e;
    var i;
    var prevText;
    var postText;
    var testSpace;
    var curUrl;
    var nodeList;
    var re = /https?:\/\//;
    w = p.walker();

    while((e = w.next())) {
        if(e.node.type == 'text') {
            i = e.node.literal.search(re);

            if(i > -1) {
                prevText = e.node.literal.substr(0,i);
                curUrl = e.node.literal.substr(i);
                nodeList = [];
                nodeList.push(e.node);
            }
            else if(curUrl !== undefined) {
                testSpace = e.node.literal.substr(0,e.node.literal.indexOf(' '));

                if(testSpace.length > 0) {
                    nodeList.push(e.node);
                    curUrl += testSpace;
                    postText = e.node.literal.substr(e.node.literal.indexOf(' ')+1);

                    if(prevText !== undefined && prevText.length > 0) {
                        prevText = parser.parse(prevText);
                        prevText.firstChild.firstChild.literal += ' ';
                        nodeList[0].insertBefore(prevText.firstChild.firstChild);
                    }

                    if(postText !== undefined && postText.length > 0) {
                        postText = parser.parse(postText);
                        postText.firstChild.firstChild.literal = ' ' + postText.firstChild.firstChild.literal;
                        nodeList[nodeList.length - 1].insertAfter(postText.firstChild.firstChild);
                    }

                    curUrl = parser.parse('[' + curUrl + '](' + curUrl +')');
                    nodeList[0].insertAfter(curUrl.firstChild.firstChild);

                    nodeList.forEach(function(n) {
                        n.unlink();
                    });

                    prevText = undefined;
                    postText = undefined;
                    curUrl = undefined;
                    nodeList = undefined;
                }
                else {
                    curUrl += e.node.literal
                    nodeList.push(e.node);
                }
            }
        }
    }

    if(curUrl !== undefined) {
        if(prevText !== undefined && prevText.length > 0) {
            prevText = parser.parse(prevText);
            prevText.firstChild.firstChild.literal += ' ';
            nodeList[0].insertBefore(prevText.firstChild.firstChild);
        }

        if(postText !== undefined && postText.length > 0) {
            postText = parser.parse(postText);
            postText.firstChild.firstChild.literal = ' ' + postText.firstChild.firstChild.literal;
            nodeList[nodeList.length - 1].insertAfter(postText.firstChild.firstChild);
        }

        curUrl = parser.parse('[' + curUrl + '](' + curUrl +')');
        nodeList[0].insertAfter(curUrl.firstChild.firstChild);

        nodeList.forEach(function(n) {
            n.unlink();
        });
    }

    return p;
}


function appendMessage(msg) {
  var newMsg = document.createElement('div');
  var nameDiv = document.createElement('div');
  var msgDiv = document.createElement('div');
  var t;
  var p;

  newMsg.className = 'chatmessage';
  if(msg.user_id) {
    newMsg.className += ' private';
    msg.from.name = msg.from.name + ' -> ' + msg.user_nick
  }

  nameDiv.className = 'name';
  nameDiv.innerHTML = icons[msg.network];

  msgDiv.className = 'message';

  if(msg.type === "emote") {
    if(msg.markdown !== undefined && msg.markdown !== null) {
      t = msg.from.name + ' ' + msg.markdown;
      p = linkify(parser.parse(t));

      nameDiv.innerHTML = nameDiv.innerHTML + writer.render(p);
    }
    else {
      t = msg.from.name + ' ' + msg.text;
      nameDiv.innerHTML = nameDiv.innerHTML + '<p>' + t + '</p>';
    }
  }
  else {
    nameDiv.innerHTML = nameDiv.innerHTML + '<p>' + msg.from.name + '</p>';
    if(msg.markdown !== undefined && msg.markdown !== null) {
      p = linkify(parser.parse(msg.markdown));

      msgDiv.innerHTML = writer.render(p);
    }
    else {
      msgDiv.innerHTML = '<p>' + msg.text + '</p>';
    }
  }
  newMsg.appendChild(nameDiv);
  newMsg.appendChild(msgDiv);

  var shouldScroll = atBottom(chatMessages);

  chatMessages.appendChild(newMsg);
  if(shouldScroll) {
    scroller.toY(chatMessages.scrollHeight);
  }
}

function updateAccountList(accounts) {
    accountList = [];
    Object.keys(accounts).forEach(function(id) {
        accounts[id].id = parseInt(id,10);
        accounts[id].viewer_count = null;
        accountList.push(accounts[id]);
    });
    accountList.sort(function(a,b) {
        var netSort = a.network.displayName.localeCompare(b.network.displayName);
        if(netSort == 0) {
            return a.name.localeCompare(b.name);
        }
        return netSort;
    });
}

function updateViewCountResult(data) {
   if(chatViewers !== null) {
       while(chatViewers.firstChild) {
           chatViewers.removeChild(chatViewers.firstChild);
       }
       var live_div = document.createElement('div');
       var live_sp = document.createElement('span');

       if(live) {
           live_sp.className = 'live';
           live_sp.innerHTML = 'Live';
           live_div.appendChild(live_sp);
           chatViewers.appendChild(live_div);

           accountList.forEach(function(v) {
               if(v.live === true) {
                   var count = 'unknown';
                   var displayName = v.network.displayName;

                   if (data !== undefined && v.id === data.account_id) {
                     v.viewer_count = data.viewer_count
                   }
                   var el = document.createElement('div');
                   var sp = document.createElement('span');
                   if(v.viewer_count !== null) {
                       count = v.viewer_count;
                   }
                   if(v.http_url !== undefined) {
                     displayName = '<a href="' + v.http_url + '" target="_blank">' + displayName + '</a>';
                   }
                   sp.innerHTML = displayName + ': ' + count;
                   el.appendChild(sp);
                   chatViewers.appendChild(el);
               }
           });
       }
       else {
           live_sp.className = 'offline';
           live_sp.innerHTML = 'Offline';
           live_div.appendChild(live_sp);
           chatViewers.appendChild(live_div);
       }
   }
}

function start_chat(endpoint) {
  if(findGetParameter('from_bottom')) {
      chatMessages.style['justify-content'] = 'flex-end';
  }

  ws = new WebSocket(endpoint);
  ws.onopen = function() {
      var msg = {
          type: 'status',
      };
      ws.send(JSON.stringify(msg));
  };

  ws.onclose = function(e) {
      live = false;
      updateViewCountResult();
  };
  
  ws.onerror = function(e) {
      live = false;
      updateViewCountResult();
  };

  ws.onmessage = function(msg) {
    var data = null;
    try {
      data = JSON.parse(msg.data);
    } catch (e) {
      /* gotta catch em all! */
    }
    if(data === null) {
      return;
    }
    if(data.type === 'text' || data.type === 'emote') {
        if(data.network !== 'irc' || !findGetParameter('hide_irc')) {
            appendMessage(data);
        }
    }
    if(data.type === 'viewcountresult') {
        updateViewCountResult(data);
    }
    if(data.type === 'writerresult') {
        if(data.account_id == curAccount.id &&
           data.cur_stream_account_id == tarAccount.id) {
          var inputElement = buildChatBox(curAccount,tarAccount)
          var p = curInput.parentElement;
          p.removeChild(curInput);
          p.appendChild(inputElement);
          curInput = inputElement;
          curInput.focus();
          p.parentElement.firstChild.firstChild.onclick = function() {
              buildChatPickerList(accountList);
          };
        }
    }
    if(data.type == 'status') {
        if(data.status.data_pushing === true) {
            live = true;
            updateAccountList(data.accounts);
            updateViewCountResult();
            if(curInput === undefined || curAccount.id > 0) {
                buildChatInput(null);
            }
        }
        else if(data.status.data_pushing === false) {
            live = false;
            updateAccountList(data.accounts);
            if(curInput === undefined || curAccount.id > 0) {
                buildChatInput(null);
            }
        }
    }
  };
};
