//! The socket to the kernel (patch 2932, bsd/dev/laurel_awdl_ctl.c) and the IPv6 set-up of awdl0. iOS only. libc by hand: the build has no crates.io.
use std::ffi::c_void;
use std::io;

const PF_SYSTEM: i32 = 32;
const SOCK_DGRAM: i32 = 2;
const SYSPROTO_CONTROL: i32 = 2;
const AF_SYS_CONTROL: u16 = 2;
const CTLIOCGINFO: u64 = 0xC064_4E03; // _IOWR('N', 3, struct ctl_info), 100 bytes
const F_SETFL: i32 = 4;
const O_NONBLOCK: i32 = 4;
const POLLIN: i16 = 1;
const AF_INET6: i32 = 30;
const SIOCPROTOATTACH_IN6: u64 = 0xC080_696E; // _IOWR('i', 110, struct in6_aliasreq_64), 128 bytes
const SIOCLL_START: u64 = 0xC080_6982; // _IOWR('i', 130, struct in6_aliasreq_64)
const SIOCGIFFLAGS: u64 = 0xC020_6911;
const SIOCSIFFLAGS: u64 = 0x8020_6910;
const IFF_UP: i16 = 1;

const OPT_STATUS: i32 = 1;

#[repr(C)]
struct CtlInfo {
    id: u32,
    name: [u8; 96],
}

#[repr(C)]
struct SockaddrCtl {
    len: u8,
    family: u8,
    sysaddr: u16,
    id: u32,
    unit: u32,
    reserved: [u32; 5],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

#[repr(C)]
#[derive(Default, Clone, Copy, Debug)]
pub struct Status {
    pub state: u32,
    pub freq: u32,
    pub why: u32,
    pub why_value: u32,
    pub en0_state: u32,
    pub en0_freq: u32,
    pub heard: u32,
    pub rx_mgmt: u32,
    pub rx_data: u32,
    pub tx_mgmt: u32,
    pub tx_data: u32,
    pub tx_full: u32,
    pub ble_age_s: u32,
    pub mode_shared: u32,
    pub peers: u32,
    pub fw_fatal: u32,
    pub off_age_ms: u32,
}

pub const STATE_OFF: u32 = 0;
pub const STATE_STARTING: u32 = 3;
pub const STATE_UP: u32 = 4;
pub const WHY_START_STATUS: u32 = 5;
pub const WHY_START_TIMEOUT: u32 = 6;

unsafe extern "C" {
    fn socket(domain: i32, ty: i32, proto: i32) -> i32;
    fn ioctl(fd: i32, req: u64, ...) -> i32;
    fn connect(fd: i32, addr: *const c_void, len: u32) -> i32;
    fn fcntl(fd: i32, cmd: i32, ...) -> i32;
    fn send(fd: i32, buf: *const c_void, len: usize, flags: i32) -> isize;
    fn recv(fd: i32, buf: *mut c_void, len: usize, flags: i32) -> isize;
    fn getsockopt(fd: i32, level: i32, opt: i32, val: *mut c_void, len: *mut u32) -> i32;
    fn poll(fds: *mut PollFd, n: u32, timeout_ms: i32) -> i32;
    fn close(fd: i32) -> i32;
    fn sysctlbyname(name: *const u8, old: *mut c_void, oldlen: *mut usize, new: *const c_void, newlen: usize) -> i32;
}

/// A string sysctl; empty when it fails.
pub fn sysctl_string(name: &str) -> String {
    let mut buf = vec![0u8; 1024];
    let mut len = buf.len();
    let mut n = name.as_bytes().to_vec();
    n.push(0);
    // SAFETY: a NUL-terminated name and a buffer of len bytes.
    if unsafe { sysctlbyname(n.as_ptr(), buf.as_mut_ptr() as *mut c_void, &mut len, std::ptr::null(), 0) } != 0 {
        return String::new();
    }
    buf.truncate(len);
    String::from_utf8_lossy(&buf).trim_end_matches(char::from(0)).to_string()
}

pub struct Ctl {
    fd: i32,
}

impl Ctl {
    pub fn open() -> io::Result<Ctl> {
        // SAFETY: plain system calls on our own descriptor and structs of the kernel's layout.
        unsafe {
            let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            let mut info = CtlInfo { id: 0, name: [0; 96] };
            info.name[..15].copy_from_slice(b"com.laurel.awdl");
            if ioctl(fd, CTLIOCGINFO, &mut info as *mut CtlInfo) != 0 {
                let e = io::Error::last_os_error();
                close(fd);
                return Err(e);
            }
            let addr = SockaddrCtl { len: 32, family: PF_SYSTEM as u8, sysaddr: AF_SYS_CONTROL, id: info.id, unit: 0, reserved: [0; 5] };
            if connect(fd, &addr as *const SockaddrCtl as *const c_void, 32) != 0 {
                let e = io::Error::last_os_error();
                close(fd);
                return Err(e);
            }
            fcntl(fd, F_SETFL, O_NONBLOCK);
            Ok(Ctl { fd })
        }
    }

    pub fn status(&self) -> io::Result<Status> {
        let mut s = Status::default();
        let mut len = std::mem::size_of::<Status>() as u32;
        // SAFETY: the kernel writes at most len bytes into s.
        if unsafe { getsockopt(self.fd, SYSPROTO_CONTROL, OPT_STATUS, &mut s as *mut Status as *mut c_void, &mut len) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(s)
    }

    /// A message: its kind, then the body. `Err`: the kernel's refusal (ENOBUFS: its queue is full).
    pub fn send(&self, kind: u8, body: &[u8]) -> io::Result<()> {
        let mut m = Vec::with_capacity(1 + body.len());
        m.push(kind);
        m.extend_from_slice(body);
        // SAFETY: m is valid for its length.
        if unsafe { send(self.fd, m.as_ptr() as *const c_void, m.len(), 0) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// The next message, or `None` when there is none now.
    pub fn recv(&self, buf: &mut [u8]) -> io::Result<Option<usize>> {
        // SAFETY: buf is valid for its length.
        let n = unsafe { recv(self.fd, buf.as_mut_ptr() as *mut c_void, buf.len(), 0) };
        if n >= 0 {
            return Ok(Some(n as usize));
        }
        let e = io::Error::last_os_error();
        if e.kind() == io::ErrorKind::WouldBlock { Ok(None) } else { Err(e) }
    }

    /// Waits for a message, at most this long.
    pub fn wait(&self, ms: i32) {
        let mut p = PollFd { fd: self.fd, events: POLLIN, revents: 0 };
        // SAFETY: one entry, valid for the call.
        let _ = unsafe { poll(&mut p, 1, ms) };
    }
}

impl Drop for Ctl {
    fn drop(&mut self) {
        // SAFETY: our descriptor. The kernel ends the vdev when the socket closes.
        unsafe { close(self.fd) };
    }
}

/// awdl0 down at the end of a session: no radio under it, so the stack must not send there. `ipv6_up` brings it back.
pub fn if_down() {
    // SAFETY: requests of the kernel's layout, zero but for the name.
    unsafe {
        let fd = socket(AF_INET6, SOCK_DGRAM, 0);
        if fd < 0 {
            return;
        }
        let mut ifr = [0u8; 32];
        ifr[..5].copy_from_slice(b"awdl0");
        if ioctl(fd, SIOCGIFFLAGS, ifr.as_mut_ptr()) == 0 {
            let flags = i16::from_ne_bytes([ifr[16], ifr[17]]) & !IFF_UP;
            ifr[16..18].copy_from_slice(&flags.to_ne_bytes());
            let _ = ioctl(fd, SIOCSIFFLAGS, ifr.as_mut_ptr());
        }
        close(fd);
    }
}

/// awdl0 up, with IPv6 and its link-local address, as configd does for an interface: the kernel makes the EUI-64 address from the interface's MAC (NET-1).
pub fn ipv6_up() -> io::Result<()> {
    // SAFETY: requests of the kernel's layout, zero but for the name.
    unsafe {
        let fd = socket(AF_INET6, SOCK_DGRAM, 0);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut ifr = [0u8; 32];
        ifr[..5].copy_from_slice(b"awdl0");
        let mut r = 0;
        if ioctl(fd, SIOCGIFFLAGS, ifr.as_mut_ptr()) == 0 {
            let flags = i16::from_ne_bytes([ifr[16], ifr[17]]) | IFF_UP;
            ifr[16..18].copy_from_slice(&flags.to_ne_bytes());
            r |= ioctl(fd, SIOCSIFFLAGS, ifr.as_mut_ptr());
        } else {
            r = -1;
        }
        let mut req = [0u8; 128];
        req[..5].copy_from_slice(b"awdl0");
        let attach = ioctl(fd, SIOCPROTOATTACH_IN6, req.as_mut_ptr());
        let e_attach = io::Error::last_os_error();
        let mut req = [0u8; 128];
        req[..5].copy_from_slice(b"awdl0");
        let ll = ioctl(fd, SIOCLL_START, req.as_mut_ptr());
        let e_ll = io::Error::last_os_error();
        close(fd);
        if r != 0 {
            return Err(io::Error::other("awdl0 would not come up"));
        }
        // (EEXIST from an earlier session is no failure)
        if attach != 0 && e_attach.raw_os_error() != Some(17) {
            return Err(e_attach);
        }
        if ll != 0 && e_ll.raw_os_error() != Some(17) {
            return Err(e_ll);
        }
    }
    Ok(())
}
