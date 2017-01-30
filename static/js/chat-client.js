/* messages look like: {"account_id":7,"stream_id":1,"markdown":"test","type":"text","from":{"name":"jprjr","id":"80787634"},"network":"twitch","text":"test"} */
/* emotes: {"account_id":7,"stream_id":1,"markdown":"is loving this thing yay","type":"emote","from":{"name":"jprjr","id":"80787634"},"network":"twitch","text":"is loving this thing yay"} */

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
var ws;
var live = false;
var refresher;

function atBottom(elem) {
    return elem.scrollHeight - elem.scrollTop === elem.clientHeight;
}

function buildRefreshTimer() {
    while(chatViewers.firstChild) {
        chatViewers.removeChild(chatViewers.firstChild);
    }
    var el = document.createElement('div');
    var sp = document.createElement('span');
    sp.className = 'live';
    sp.innerHTML = 'Live';
    el.appendChild(sp);
    chatViewers.appendChild(el);

    refresher = function() {
        if (live === true) {
            ws.send(JSON.stringify({
                type: 'viewcount',
            }));
            setTimeout(refresher,60 * 1000);
        }
        else {
            while(chatViewers.firstChild) {
                chatViewers.removeChild(chatViewers.firstChild);
            }
            var el = document.createElement('div');
            var sp = document.createElement('span');
            sp.className = 'offline';
            sp.innerHTML = 'Offline';
            el.appendChild(sp);
            chatViewers.appendChild(el);
        }
    };
    refresher();
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
    if(accounts !== undefined && accounts !== null) {
        accounts.forEach(function(account) {
            if(icons[account.network] && account.writable === true) {
                var chatPicker = document.createElement('div');
                chatPicker.className = 'chatpicker';
                chatPicker.innerHTML = icons[account.network] + '<p>' + account.name + '</p>';
                chatPicker.onclick = function() {
                    buildChatInput(account);
                };
                chatPickerList.appendChild(chatPicker);
            }
        });
    }
    else {
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

function buildChatBox(account) {
    var inputElement = document.createElement('input');
    inputElement.onkeypress = function(e) {
        var event = e || window.event;
        var charCode = event.which || event.keyCode;

        if(charCode === 13) {
            var msg = inputElement.value;
            inputElement.value = '';
            ws.send(JSON.stringify({
                type: 'comment',
                account_id: account.id,
                text: msg
            }));
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
        nameElement.innerHTML = icons[account.network] + '<p>' + account.name + '</p>';
        curAccount = account;
        if(account.ready === true) {
            inputElement = buildChatBox(account);
            curInput = inputElement;
        }
        else {
            var liveAccounts = []
            accountList.forEach(function(a) {
              if(a.live === true && a.network.localeCompare(account.network) === 0) {
                  liveAccounts.push(a);
              }
            });
            if(liveAccounts.length == 1) {
                inputElement = buildChatBox(account);
                inputElement.disabled = true;
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
                inputElement.appendChild(firstOpt);
                liveAccounts.forEach(function(a) {
                    var optionElement = document.createElement('option');
                    optionElement.innerHTML = a.name;
                    optionElement.value = a.id;
                    inputElement.appendChild(optionElement);
                });
                inputElement.onchange = function() {
                    inputElement.disabled = true;
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
            nameElement.innerHTML = '<p>No account chosen</p>';
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
    chatWrapper.appendChild(chatInput);
}


function appendMessage(msg) {
  var newMsg = document.createElement('div');
  var nameDiv = document.createElement('div');
  var msgDiv = document.createElement('div');
  var t;
  var p;

  newMsg.className = 'chatmessage';

  nameDiv.className = 'name';
  nameDiv.innerHTML = icons[msg.network];

  msgDiv.className = 'message';

  if(msg.type === "emote") {
    t = msg.from.name + ' ' + msg.markdown;
    p = parser.parse(t);

    nameDiv.innerHTML = nameDiv.innerHTML + writer.render(p);
  }
  else {
    p = parser.parse(msg.markdown)
    nameDiv.innerHTML = nameDiv.innerHTML + '<p>' + msg.from.name + '</p>';
    msgDiv.innerHTML = writer.render(p);
  }
  newMsg.appendChild(nameDiv);
  newMsg.appendChild(msgDiv);

  var shouldScroll = atBottom(chatMessages);

  chatMessages.appendChild(newMsg);
  if(shouldScroll) {
    chatMessages.scrollTop = chatMessages.scrollHeight;
  }
}

function updateAccountList(accounts) {
    accountList = [];
    Object.keys(accounts).forEach(function(id) {
        accounts[id].id = parseInt(id,10);
        accountList.push(accounts[id]);
    });
    accountList.sort(function(a,b) {
        var netSort = a.network.localeCompare(b.network);
        if(netSort == 0) {
            return a.name.localeCompare(b.name);
        }
        return netSort;
    });
}

function start_chat(endpoint) {
  ws = new WebSocket(endpoint);
  ws.onopen = function() {
      var msg = {
          type: 'status',
      };
      ws.send(JSON.stringify(msg));
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
        appendMessage(data);
    }
    if(data.type === 'viewcountresult') {
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
            data.viewcounts.sort(function(a,b) {
                return a.network.displayname.localeCompare(b.network.displayname);
            });
            data.viewcounts.forEach(function(v) {
                var el = document.createElement('div');
                var sp = document.createElement('span');
                if(v.viewcount === undefined) {
                    v.viewcount = 'unknown';
                }
                sp.innerHTML = v.network.displayname + ': ' + v.viewcount;
                el.appendChild(sp);
                chatViewers.appendChild(el);
            });
        }
        else {
            live_sp.className = 'offline';
            live_sp.innerHTML = 'Offline';
            live_div.appendChild(live_sp);
            chatViewers.appendChild(live_div);
        }
    }
    if(data.type === 'writerresult') {
        var inputElement = buildChatBox(curAccount)
        var p = curInput.parentElement;
        p.removeChild(curInput);
        p.appendChild(inputElement);
    }
    if(data.type == 'status') {
        if(data.status === 'live') {
            live = true;
            updateAccountList(data.accounts);
            buildChatInput(null);
            buildRefreshTimer();
        }
        else if(data.status === 'end') {
            live = false;
            accountList = undefined;
            buildChatInput(null);
        }
    }
  };
};
