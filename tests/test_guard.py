from vpnctl import guard


def test_ssh_no_pty_process_name_is_detected():
    assert guard._ssh_session_username("sshd: testuser") == "testuser"
    assert guard._ssh_session_username("sshd: testuser@notty") == "testuser"
    assert guard._ssh_session_username("sshd: testuser [priv]") is None


def test_openvpn_status_v3_uses_client_id_and_connected_time(monkeypatch):
    monkeypatch.setattr(
        guard,
        "_management",
        lambda proto: (
            "HEADER,CLIENT_LIST,Common Name,Real Address,Virtual Address,"
            "Virtual IPv6 Address,Bytes Received,Bytes Sent,Connected Since,"
            "Connected Since (time_t),Username,Client ID,Peer ID,Data Channel Cipher\n"
            "CLIENT_LIST,test-user,192.0.2.4:1234,10.8.0.2,,100,200,"
            "Tue Oct  6 09:00:00 2026,1791277200,test-user,42,0,AES-256-GCM\n"
            "END\n"
        ),
    )

    sessions = guard.openvpn_sessions()

    assert sessions == [
        {
            "username": "test-user",
            "proto": "tcp",
            "connected": 1791277200,
            "client_id": "42",
        },
        {
            "username": "test-user",
            "proto": "udp",
            "connected": 1791277200,
            "client_id": "42",
        },
    ]


def test_openvpn_status_v3_tab_delimiter(monkeypatch):
    monkeypatch.setattr(
        guard,
        "_management",
        lambda proto: (
            "HEADER\tCLIENT_LIST\tCommon Name\tReal Address\tVirtual Address\t"
            "Virtual IPv6 Address\tBytes Received\tBytes Sent\tConnected Since\t"
            "Connected Since (time_t)\tUsername\tClient ID\tPeer ID\tData Channel Cipher\n"
            "CLIENT_LIST\ttest-user\t127.0.0.1:5555\t10.8.0.2\t\t400\t500\t"
            "Tue Oct  6 09:00:00 2026\t1791277200\tUNDEF\t42\t0\tAES-256-GCM\nEND\n"
        ),
    )

    sessions = guard.openvpn_sessions()

    assert sessions[0]["username"] == "test-user"
    assert sessions[0]["connected"] == 1791277200
    assert sessions[0]["client_id"] == "42"
