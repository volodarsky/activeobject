/*
 * The MIT License (MIT)
 *
 * Copyright (c) 2015 Igor Konev
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

package org.jvnet.zephyr.activeobject.aspect;

import org.jvnet.zephyr.activeobject.annotation.Active;
import org.jvnet.zephyr.activeobject.annotation.Exclude;
import org.jvnet.zephyr.activeobject.annotation.Include;
import org.jvnet.zephyr.activeobject.annotation.Oneway;
import org.jvnet.zephyr.activeobject.disposer.Disposable;
import org.jvnet.zephyr.activeobject.disposer.Disposer;
import org.jvnet.zephyr.activeobject.mailbox.Mailbox;
import org.jvnet.zephyr.activeobject.mailbox.MailboxFactory;
import org.jvnet.zephyr.activeobject.mailbox.ReflectiveMailboxFactory;
import org.jvnet.zephyr.activeobject.util.concurrent.RunnableFutureTask;

import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.RunnableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

public final aspect ActiveObjectAspect pertypewithin(ActiveObject+) {

    declare error: execution(@Include @Exclude * *.*(..)): "@Include and @Exclude on the same method are not allowed";
    declare error: execution(@Include static * *.*(..)): "@Include on a static method is not allowed";
    declare error: execution(@Exclude static * *.*(..)): "@Exclude on a static method is not allowed";
    declare error: execution(@Oneway static * *.*(..)): "@Oneway on a static method is not allowed";
    declare error: execution(@Oneway !void *.*(..)): "@Oneway requires void return type";
    declare error: execution(@Oneway * *.*(..) throws Throwable+ && !(Error+ || RuntimeException+)):
            "@Oneway allows throwing unchecked exceptions only";
    declare warning: execution(@Include public * *.*(..)): "@Include on a public method is redundand";
    declare warning: execution(@Exclude !public * *.*(..)): "@Exclude on a non-public method is redundand";
    declare parents: @Active * implements ActiveObject;

    private Class<?> declaringType;
    private Disposer disposer;
    private MailboxFactory mailboxFactory;
    private long timeout;
    private volatile ActiveObjectThread ActiveObject.thread;

    before(): staticinitialization(ActiveObject+) {
        declaringType = thisJoinPointStaticPart.getSignature().getDeclaringType();
        disposer = new Disposer("Disposer of " + declaringType.getName());
        Active annotation = declaringType.getAnnotation(Active.class);

        Class<?> cls = annotation.mailbox();
        Constructor<?> constructor;
        try {
            constructor = (Constructor<?>) cls.getConstructor();
        } catch (NoSuchMethodException e) {
            throw new RuntimeException(e);
        }
        if (Mailbox.class.isAssignableFrom(cls)) {
            mailboxFactory = new ReflectiveMailboxFactory((Constructor<? extends Mailbox>) constructor);
        } else {
            try {
                mailboxFactory = (MailboxFactory) constructor.newInstance();
            } catch (InstantiationException | IllegalAccessException e) {
                throw new RuntimeException(e);
            } catch (InvocationTargetException e) {
                Throwable cause = e.getCause();
                if (cause instanceof Error) {
                    throw (Error) cause;
                } else if (cause instanceof RuntimeException) {
                    throw (RuntimeException) cause;
                } else {
                    throw new RuntimeException(cause);
                }
            }
        }

        timeout = annotation.timeout();
        if (timeout < 0) {
            throw new RuntimeException("timeout < 0");
        }
    }

    before(ActiveObject obj): initialization((ActiveObject+ && !ActiveObject).new(..)) && this(obj) {
        if (obj.getClass() == declaringType) {
            ActiveObjectThread thread = new ActiveObjectThread(mailboxFactory.create());
            thread.setName(obj.getClass().getName() + '@' + Integer.toHexString(System.identityHashCode(obj)));
            thread.setDaemon(true);
            disposer.register(obj, thread);
            thread.running = true;
            thread.start();
            obj.thread = thread;
        }
    }

    Object around(final ActiveObject obj): (execution(!@Exclude !@Oneway public * ActiveObject+.*(..))
            || execution(@Include !@Oneway !public * ActiveObject+.*(..))) && this(obj) {
        ActiveObjectThread thread = obj.thread;
        if (Thread.currentThread() == thread) {
            return proceed(obj);
        }

        RunnableFuture<?> task = new RunnableFutureTask<Object>() {
            @Override
            public void run() {
                Object result;
                try {
                    result = proceed(obj);
                } catch (Throwable e) {
                    setException(e);
                    return;
                }
                set(result);
            }
        };

        boolean interrupted = false;
        try {
            while (true) {
                try {
                    thread.mailbox.enqueue(task);
                    break;
                } catch (InterruptedException ignored) {
                    interrupted = true;
                }
            }
        } finally {
            if (interrupted) {
                Thread.currentThread().interrupt();
            }
        }

        try {
            interrupted = false;
            try {
                while (true) {
                    try {
                        if (timeout > 0) {
                            try {
                                return task.get(timeout, TimeUnit.MILLISECONDS);
                            } catch (TimeoutException e) {
                                throw new RuntimeException(e);
                            }
                        } else {
                            return task.get();
                        }
                    } catch (InterruptedException ignored) {
                        interrupted = true;
                    }
                }
            } finally {
                if (interrupted) {
                    Thread.currentThread().interrupt();
                }
            }
        } catch (ExecutionException e) {
            throw ActiveObjectAspect.<RuntimeException>throwException(e.getCause());
        }
    }

    @SuppressWarnings("unchecked")
    private static <E extends Throwable> E throwException(Throwable exception) throws E {
        throw (E) exception;
    }

    void around(final ActiveObject obj): (execution(!@Exclude @Oneway public void ActiveObject+.*(..))
            || execution(@Include @Oneway !public void ActiveObject+.*(..))) && this(obj) {
        Runnable task = new Runnable() {
            @Override
            public void run() {
                try {
                    proceed(obj);
                } catch (Throwable e) {
                    e.printStackTrace();
                }
            }
        };

        boolean interrupted = false;
        try {
            while (true) {
                try {
                    obj.thread.mailbox.enqueue(task);
                    break;
                } catch (InterruptedException ignored) {
                    interrupted = true;
                }
            }
        } finally {
            if (interrupted) {
                Thread.currentThread().interrupt();
            }
        }
    }

    private interface ActiveObject {
    }

    private static final class ActiveObjectThread extends Thread implements Disposable {

        final Mailbox mailbox;
        volatile boolean running;

        ActiveObjectThread(Mailbox mailbox) {
            this.mailbox = mailbox;
        }

        @Override
        public void run() {
            while (running) {
                Runnable task;
                try {
                    task = (Runnable) mailbox.dequeue();
                } catch (InterruptedException ignored) {
                    continue;
                }
                task.run();
            }
        }

        @Override
        public void dispose() {
            running = false;
            interrupt();
        }
    }
}
